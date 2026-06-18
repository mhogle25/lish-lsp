//! Workspace macro index: macro name -> where it is defined.
//!
//! lish macro names are flat and global by design (no source-level modules or
//! namespacing; prefix conventions and runtime registry parents fill that role),
//! so a macro called from a `.lish` script is just a bare name. To offer
//! go-to-definition we scan the workspace's `.lishmacro` files and remember each
//! macro's header location. The index also stores a rendered signature so hover
//! and token classification can recognise a user macro without re-parsing its
//! file.
//!
//! The data structure is deliberately dumb: build/clear/lookup plus the source
//! indexers. Freshness policy (when to rebuild) lives in the server. Open
//! documents take precedence over their on-disk copies, so unsaved edits win.

const std = @import("std");
const lish = @import("lish");
const uri = @import("uri.zig");
const document_store = @import("document_store.zig");

const Allocator = std.mem.Allocator;
const DocumentStore = document_store.DocumentStore;

/// Directory names never descended into during a scan.
const SKIP_DIRS = [_][]const u8{ "node_modules", ".git", ".zig-cache", "zig-out" };
/// Maximum directory depth below a root (1 = a direct child).
const MAX_DEPTH = 16;
/// Guardrail against pathological trees: stop a root scan after this many entries.
const MAX_ENTRIES_PER_ROOT = 20_000;

/// Where a macro is defined.
pub const MacroDef = struct {
    /// `file://` URI of the defining document.
    uri: []const u8,
    /// Byte span of the header identifier within that document.
    start: u32,
    end: u32,
    /// Call signature rendered from the head, e.g. `clamp lo hi x`.
    signature: []const u8,
};

pub const WorkspaceIndex = struct {
    /// name -> def. Keys, URIs, and signatures are owned by `arena`.
    map: std.StringHashMapUnmanaged(MacroDef) = .empty,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) WorkspaceIndex {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *WorkspaceIndex) void {
        self.arena.deinit();
    }

    /// Drop every entry, keeping arena pages for reuse on the next build.
    pub fn clear(self: *WorkspaceIndex) void {
        _ = self.arena.reset(.retain_capacity);
        self.map = .empty;
    }

    pub fn lookup(self: *const WorkspaceIndex, name: []const u8) ?MacroDef {
        return self.map.get(name);
    }

    /// Parse `source` as a macro module and record each macro it defines under
    /// `doc_uri`. `scratch` holds the throwaway parse; kept strings are duped
    /// into the index arena. First definition of a name wins (redefinition is
    /// already a lish error).
    pub fn indexSource(self: *WorkspaceIndex, scratch: Allocator, doc_uri: []const u8, source: []const u8) Allocator.Error!void {
        const module = try lish.macro_parser.parseMacroModule(scratch, source);
        const arena = self.arena.allocator();

        for (module.macros) |node| {
            const macro = switch (node) {
                .macro => |m| m,
                .err => continue,
            };
            const id = switch (macro.id) {
                .valid => |d| d,
                .err => continue,
            };

            const gop = try self.map.getOrPut(arena, id.name);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try arena.dupe(u8, id.name);
            gop.value_ptr.* = .{
                .uri = try arena.dupe(u8, doc_uri),
                .start = id.position.start,
                .end = id.position.end,
                .signature = try renderSignature(arena, macro),
            };
        }
    }

    /// Index every open `.lishmacro` document in the store (from its live text).
    /// The per-document parse is freed before moving to the next, so peak
    /// transient memory is bounded by the largest single document.
    pub fn indexOpenDocs(self: *WorkspaceIndex, gpa: Allocator, store: *DocumentStore) Allocator.Error!void {
        var transient = std.heap.ArenaAllocator.init(gpa);
        defer transient.deinit();

        var it = store.map.iterator();
        while (it.next()) |entry| {
            const doc_uri = entry.key_ptr.*;
            if (!std.mem.endsWith(u8, doc_uri, lish.MACRO_EXTENSION)) continue;
            try self.indexSource(transient.allocator(), doc_uri, entry.value_ptr.text);
            _ = transient.reset(.retain_capacity);
        }
    }

    /// Rebuild from scratch: open documents first (so unsaved edits win), then
    /// every `.lishmacro` on disk under `roots` that is not already open. `gpa`
    /// is a general allocator; build owns a transient arena it resets per file,
    /// so peak transient memory is one file's parse, not the whole workspace's.
    pub fn build(self: *WorkspaceIndex, io: std.Io, gpa: Allocator, roots: []const []const u8, store: *DocumentStore) Allocator.Error!void {
        self.clear();

        var transient = std.heap.ArenaAllocator.init(gpa);
        defer transient.deinit();

        // Open documents win over their on-disk copies; record their URIs so the
        // disk scan can skip re-reading them.
        var open_uris: std.StringHashMapUnmanaged(void) = .empty;
        defer open_uris.deinit(gpa);

        var it = store.map.iterator();
        while (it.next()) |entry| {
            const doc_uri = entry.key_ptr.*;
            if (!std.mem.endsWith(u8, doc_uri, lish.MACRO_EXTENSION)) continue;
            try self.indexSource(transient.allocator(), doc_uri, entry.value_ptr.text);
            try open_uris.put(gpa, doc_uri, {});
            _ = transient.reset(.retain_capacity);
        }

        for (roots) |root| self.scanRoot(io, gpa, root, &open_uris) catch continue;
    }

    /// Walk one root for `.lishmacro` files, skipping files already indexed from
    /// an open document. The walker uses `gpa` directly (its state must persist
    /// across the walk); per-file work goes through a transient arena reset after
    /// each file. Best-effort: a directory or file that fails is skipped rather
    /// than aborting the scan.
    fn scanRoot(
        self: *WorkspaceIndex,
        io: std.Io,
        gpa: Allocator,
        root: []const u8,
        open_uris: *std.StringHashMapUnmanaged(void),
    ) !void {
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();

        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();

        var visited: usize = 0;
        while (try walker.next(io)) |entry| {
            visited += 1;
            if (visited > MAX_ENTRIES_PER_ROOT) return;

            switch (entry.kind) {
                .directory => {
                    if (shouldSkipDir(entry.basename)) continue;
                    if (entry.depth() >= MAX_DEPTH) continue;
                    walker.enter(io, entry) catch continue;
                },
                .file => {
                    defer _ = file_arena.reset(.retain_capacity);
                    if (!std.mem.endsWith(u8, entry.basename, lish.MACRO_EXTENSION)) continue;

                    const scratch = file_arena.allocator();
                    const full_path = std.fs.path.join(scratch, &.{ root, entry.path }) catch continue;
                    const file_uri = uri.fromPath(scratch, full_path) catch continue;
                    if (open_uris.contains(file_uri)) continue;
                    const source = entry.dir.readFileAlloc(io, entry.basename, scratch, .limited(lish.MACRO_FILE_MAX_SIZE)) catch continue;
                    self.indexSource(scratch, file_uri, source) catch continue;
                },
                else => {},
            }
        }
    }
};

/// Skip hidden directories and the well-known dependency/build dirs.
fn shouldSkipDir(basename: []const u8) bool {
    if (basename.len > 0 and basename[0] == '.') return true;
    for (SKIP_DIRS) |skip| {
        if (std.mem.eql(u8, basename, skip)) return true;
    }
    return false;
}

/// Render a macro's call signature (`name p1 ~p2`) into `arena`.
fn renderSignature(arena: Allocator, macro: lish.macro_parser.AstMacro) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, macro.id.valid.name);
    for (macro.parameters) |param_node| {
        if (param_node != .valid) continue;
        const param = param_node.valid;
        try buf.append(arena, ' ');
        if (param.param_type == .deferred) try buf.append(arena, lish.token.DEFERRED);
        try buf.appendSlice(arena, param.id);
    }
    return buf.toOwnedSlice(arena);
}

// Tests

const testing = std.testing;

test "indexSource records a macro's header position and signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // "| double x | * :x 2" — "double" header id at bytes [2,8).
    try index.indexSource(a, "file:///lib.lishmacro", "| double x | * :x 2");

    const def = index.lookup("double") orelse return error.NotFound;
    try testing.expectEqualStrings("file:///lib.lishmacro", def.uri);
    try testing.expectEqual(@as(u32, 2), def.start);
    try testing.expectEqual(@as(u32, 8), def.end);
    try testing.expectEqualStrings("double x", def.signature);
}

test "indexSource renders deferred params with a ~" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    try index.indexSource(a, "file:///m.lishmacro", "| run ~body | if :body 1");
    const def = index.lookup("run") orelse return error.NotFound;
    try testing.expectEqualStrings("run ~body", def.signature);
}

test "indexSource is first-wins on a duplicate name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    try index.indexSource(a, "file:///first.lishmacro", "| dup x | :x");
    try index.indexSource(a, "file:///second.lishmacro", "| dup y | :y");

    const def = index.lookup("dup") orelse return error.NotFound;
    try testing.expectEqualStrings("file:///first.lishmacro", def.uri);
}

test "lookup of an unknown name returns null" {
    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try testing.expect(index.lookup("nope") == null);
}

test "clear empties the index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    try index.indexSource(a, "file:///m.lishmacro", "| foo | 1");
    try testing.expect(index.lookup("foo") != null);
    index.clear();
    try testing.expect(index.lookup("foo") == null);
}

test "indexOpenDocs indexes only .lishmacro documents from the store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var store = DocumentStore.init(testing.allocator);
    defer store.deinit();
    try store.open("file:///a.lishmacro", "| indoc x | :x", 1);
    try store.open("file:///b.lish", "(+ 1 2)", 1);

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try index.indexOpenDocs(a, &store);

    try testing.expect(index.lookup("indoc") != null);
}

test "build scans .lishmacro files on disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var io_instance: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.lishmacro", .data = "| double x | * :x 2" });

    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });

    var store = DocumentStore.init(testing.allocator);
    defer store.deinit();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try index.build(io, a, &.{root}, &store);

    const def = index.lookup("double") orelse return error.NotFound;
    try testing.expect(std.mem.endsWith(u8, def.uri, "lib.lishmacro"));
    try testing.expectEqualStrings("double x", def.signature);
}

test "build prefers an open document over its on-disk copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var io_instance: std.Io.Threaded = .init(testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.lishmacro", .data = "| onlyondisk | 1" });

    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const file_uri = try uri.fromPath(a, try std.fs.path.join(a, &.{ root, "lib.lishmacro" }));

    var store = DocumentStore.init(testing.allocator);
    defer store.deinit();
    // The open buffer defines a different macro than the saved file.
    try store.open(file_uri, "| onlyopen | 2", 2);

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try index.build(io, a, &.{root}, &store);

    try testing.expect(index.lookup("onlyopen") != null);
    try testing.expect(index.lookup("onlyondisk") == null);
}
