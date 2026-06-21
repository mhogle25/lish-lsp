//! Generic LSP server glue, shared by the lish-lsp binary and a sibling server
//! (folio-lsp). Plain helper functions, no `Server` struct: JSON-RPC response
//! framing, lifecycle gating, JSON field helpers, workspace-root collection, and
//! host-vocabulary file loading. Each language server owns its own `server.zig`
//! (struct + dispatch + handlers) and calls these for the parts that are not
//! language specific.

const std = @import("std");
const protocol = @import("protocol.zig");
const uri_mod = @import("uri.zig");
const lish_registry = @import("lish_registry.zig");
const diagnostics = @import("diagnostics.zig");

const LishRegistry = lish_registry.LishRegistry;

pub const State = enum {
    uninitialized,
    initialized,
    shutdown,
};

/// Standard JSON-RPC error codes that a server emits.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
};

/// Cap on a single host-vocabulary JSON file (a generous `--dump-ops` is well
/// under this).
pub const VOCABULARY_MAX_SIZE = 8 * 1024 * 1024;

/// Auto-discovered per-project vocabulary file, looked for at each workspace root.
pub const PROJECT_VOCABULARY_FILE = "lish.ops.json";

// --- JSON-RPC responses ---

pub fn sendResult(writer: *std.Io.Writer, id: std.json.Value, result_json: []const u8) !void {
    // Stream the framed response: the result body can be arbitrarily large
    // (semantic tokens for a big file), so it must never have to fit in a
    // fixed buffer. Only the tiny request id needs a scratch to measure its
    // length for the Content-Length header.
    var id_buf: [256]u8 = undefined;
    var id_w = std.Io.Writer.fixed(&id_buf);
    try writeIdValue(&id_w, id);
    const id_str = id_w.buffered();

    const head = "{\"jsonrpc\":\"2.0\",\"id\":";
    const mid = ",\"result\":";
    const len = head.len + id_str.len + mid.len + result_json.len + "}".len;

    try writer.print("Content-Length: {d}\r\n\r\n", .{len});
    try writer.writeAll(head);
    try writer.writeAll(id_str);
    try writer.writeAll(mid);
    try writer.writeAll(result_json);
    try writer.writeAll("}");
    try writer.flush();
}

pub fn sendError(writer: *std.Io.Writer, id: std.json.Value, code: ErrorCode, message: []const u8) !void {
    var id_buf: [256]u8 = undefined;
    var id_w = std.Io.Writer.fixed(&id_buf);
    try writeIdValue(&id_w, id);
    const id_str = id_w.buffered();

    var code_buf: [16]u8 = undefined;
    var code_w = std.Io.Writer.fixed(&code_buf);
    try code_w.print("{d}", .{@intFromEnum(code)});
    const code_str = code_w.buffered();

    // Measure the JSON-escaped message without bounding it by a fixed buffer.
    var discard_buf: [64]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&discard_buf);
    try writeJsonString(&counter.writer, message);
    const escaped_len: usize = @intCast(counter.fullCount());

    const head = "{\"jsonrpc\":\"2.0\",\"id\":";
    const mid1 = ",\"error\":{\"code\":";
    const mid2 = ",\"message\":\"";
    const tail = "\"}}";
    const len = head.len + id_str.len + mid1.len + code_str.len + mid2.len + escaped_len + tail.len;

    try writer.print("Content-Length: {d}\r\n\r\n", .{len});
    try writer.writeAll(head);
    try writer.writeAll(id_str);
    try writer.writeAll(mid1);
    try writer.writeAll(code_str);
    try writer.writeAll(mid2);
    try writeJsonString(writer, message);
    try writer.writeAll(tail);
    try writer.flush();
}

fn writeIdValue(w: *std.Io.Writer, id: std.json.Value) !void {
    switch (id) {
        .string => |s| {
            try w.writeAll("\"");
            try writeJsonString(w, s);
            try w.writeAll("\"");
        },
        .integer => |i| try w.print("{d}", .{i}),
        .number_string => |s| try w.writeAll(s),
        .null => try w.writeAll("null"),
        else => try w.writeAll("null"),
    }
}

/// Write `s` as the inner bytes of a JSON string literal (no surrounding quotes).
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
}

// --- Lifecycle ---

pub const Reject = struct { code: ErrorCode, message: []const u8 };

/// LSP lifecycle gating (uninitialized -> initialized -> shutdown). Returns the
/// rejection (code + message) if `method` may not run in `state`, else null.
pub fn lifecycleReject(state: State, method: []const u8) ?Reject {
    if (state == .uninitialized and !std.mem.eql(u8, method, "initialize") and !std.mem.eql(u8, method, "exit"))
        return .{ .code = .server_not_initialized, .message = "server not initialized" };
    if (state == .shutdown and !std.mem.eql(u8, method, "exit"))
        return .{ .code = .invalid_request, .message = "server has shut down" };
    return null;
}

// --- JSON field helpers ---

pub fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Read the `position` object (`{line, character}`) from request params.
pub fn positionOf(params: ?std.json.Value) ?diagnostics.Position {
    const p = params orelse return null;
    if (p != .object) return null;

    const pos = p.object.get("position") orelse return null;
    if (pos != .object) return null;

    const line = pos.object.get("line") orelse return null;
    const character = pos.object.get("character") orelse return null;
    if (line != .integer or character != .integer) return null;
    if (line.integer < 0 or character.integer < 0) return null;

    return .{ .line = @intCast(line.integer), .character = @intCast(character.integer) };
}

// --- Workspace roots ---

/// Record the workspace roots from `initialize` params as filesystem paths into
/// `roots`. Precedence follows the spec: `workspaceFolders` (each folder's
/// `uri`), then the deprecated `rootUri`, then the deprecated `rootPath`. URIs
/// are decoded to paths; a non-`file://` URI is skipped.
pub fn collectRoots(allocator: std.mem.Allocator, roots: *std.ArrayListUnmanaged([]const u8), params: ?std.json.Value) !void {
    const p = params orelse return;
    if (p != .object) return;

    if (p.object.get("workspaceFolders")) |folders| {
        if (folders == .array) {
            for (folders.array.items) |folder| {
                if (folder != .object) continue;
                const folder_uri = stringField(folder.object, "uri") orelse continue;
                try addRootFromUri(allocator, roots, folder_uri);
            }
            return;
        }
    }
    if (stringField(p.object, "rootUri")) |root_uri| {
        try addRootFromUri(allocator, roots, root_uri);
        return;
    }
    if (stringField(p.object, "rootPath")) |root_path| {
        try roots.append(allocator, try allocator.dupe(u8, root_path));
    }
}

fn addRootFromUri(allocator: std.mem.Allocator, roots: *std.ArrayListUnmanaged([]const u8), root_uri: []const u8) !void {
    const path = (try uri_mod.toPath(allocator, root_uri)) orelse return;
    try roots.append(allocator, path);
}

// --- Host vocabulary loading ---

/// Merge host ops into `registry` from two sources, in precedence order (the
/// first to register a given name wins; builtins, registered earlier, always
/// win): explicit `specs`, then per-project `lish.ops.json` at each root.
/// Failures are logged to `log` and skipped; an absent auto-discovered file is
/// normal and silent.
/// Returns the total number of host ops merged across all sources.
pub fn loadVocabularies(
    name: []const u8,
    project_file: []const u8,
    io: std.Io,
    log: *std.Io.Writer,
    allocator: std.mem.Allocator,
    registry: *LishRegistry,
    specs: []const []const u8,
    roots: []const []const u8,
) usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var total: usize = 0;

    // 1. Explicit setting: a missing path is a misconfiguration worth logging.
    for (specs) |spec| {
        const path = resolveVocabularyPath(scratch, roots, spec) catch continue orelse {
            log.print("{s}: cannot resolve vocabulary path '{s}' (no workspace root)\n", .{ name, spec }) catch {};
            continue;
        };
        total += mergeVocabularyFile(name, io, log, registry, scratch, path, true);
    }

    // 2. Per-project auto-discovery at each workspace root.
    for (roots) |root| {
        const path = std.fs.path.join(scratch, &.{ root, project_file }) catch continue;
        total += mergeVocabularyFile(name, io, log, registry, scratch, path, false);
    }

    log.flush() catch {};
    return total;
}

/// Read `path` and merge its ops, returning the count merged. A `required` file
/// (explicit setting) logs on read failure; an optional (auto-discovered) file
/// that is simply absent is skipped silently. Malformed JSON always logs.
pub fn mergeVocabularyFile(name: []const u8, io: std.Io, log: *std.Io.Writer, registry: *LishRegistry, scratch: std.mem.Allocator, path: []const u8, required: bool) usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .limited(VOCABULARY_MAX_SIZE)) catch |err| {
        if (required) log.print("{s}: cannot read vocabulary '{s}': {s}\n", .{ name, path, @errorName(err) }) catch {};
        return 0;
    };
    const merged = registry.loadVocabulary(bytes) catch |err| {
        log.print("{s}: invalid vocabulary '{s}': {s}\n", .{ name, path, @errorName(err) }) catch {};
        return 0;
    };
    if (merged > 0) log.print("{s}: merged {d} ops from '{s}'\n", .{ name, merged, path }) catch {};
    return merged;
}

/// Record `initializationOptions.vocabulary` (a string or array of strings) as
/// host-vocabulary file specs in `specs`. Anything else is ignored.
pub fn collectVocabularySpecs(allocator: std.mem.Allocator, specs: *std.ArrayListUnmanaged([]const u8), params: ?std.json.Value) !void {
    const p = params orelse return;
    if (p != .object) return;
    const opts = p.object.get("initializationOptions") orelse return;
    if (opts != .object) return;
    const vocab = opts.object.get("vocabulary") orelse return;
    switch (vocab) {
        .string => |s| try appendSpec(allocator, specs, s),
        .array => |arr| for (arr.items) |item| {
            if (item == .string) try appendSpec(allocator, specs, item.string);
        },
        else => {},
    }
}

fn appendSpec(allocator: std.mem.Allocator, specs: *std.ArrayListUnmanaged([]const u8), spec: []const u8) !void {
    if (spec.len == 0) return;
    try specs.append(allocator, try allocator.dupe(u8, spec));
}

/// Resolve a vocabulary spec to an absolute path: returned as-is if already
/// absolute, else joined onto the first workspace root. Null when relative and
/// no root is known.
pub fn resolveVocabularyPath(alloc: std.mem.Allocator, roots: []const []const u8, spec: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(spec)) return try alloc.dupe(u8, spec);
    if (roots.len == 0) return null;
    return try std.fs.path.join(alloc, &.{ roots[0], spec });
}
