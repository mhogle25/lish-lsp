//! `textDocument/definition`: resolve the name under the cursor to where it is
//! defined.
//!
//! Two entry points, one per document language:
//!
//!   * `defineExpression` (`.lish`) — a bare identifier that names a workspace
//!     macro jumps to that macro's header. Builtins, stdlib ops, and unknown
//!     names have no source location, so they resolve to nothing.
//!
//!   * `defineMacro` (`.lishmacro`) — inside a macro body, a scope reference
//!     (`:x`) jumps to the head parameter it names, and a bare identifier that
//!     names a macro jumps to that macro's header (a sibling in the same module
//!     first, then the workspace index). Standing on a head name or parameter,
//!     you are already at the definition, so nothing resolves.
//!
//! Locations are byte spans plus a `file://` URI; the server converts them to
//! LSP positions. Resolution is purely structural and does not run any code, so
//! computed scope keys (`:(...)`) and outer bindings are out of scope here.

const std = @import("std");
const lish = @import("lish");
const ast_walk = @import("ast_walk.zig");
const workspace_index = @import("workspace_index.zig");

const Allocator = std.mem.Allocator;
const WorkspaceIndex = workspace_index.WorkspaceIndex;
const Position = lish.ast.Position;

/// A resolved definition site: a byte span within a document.
pub const Location = struct {
    /// `file://` URI of the document the definition lives in.
    uri: []const u8,
    /// Byte span of the defining identifier.
    start: u32,
    end: u32,
};

/// Resolve go-to-definition at `cursor` in a `.lish` expression document. Only a
/// bare identifier naming a workspace macro resolves; everything else is null.
pub fn defineExpression(
    source: []const u8,
    cursor: u32,
    index: *const WorkspaceIndex,
    allocator: Allocator,
) Allocator.Error!?Location {
    const root = try lish.parser.parse(allocator, source);
    const node = ast_walk.nodeAt(root, cursor) orelse return null;
    if (!ast_walk.isBareIdentifier(node)) return null;

    const def = index.lookup(node.body.value_literal.string) orelse return null;
    return .{ .uri = def.uri, .start = def.start, .end = def.end };
}

/// Resolve go-to-definition at `cursor` in a `.lishmacro` module document.
/// `doc_uri` is this document's own URI, used for same-document jumps (a
/// parameter or a sibling macro).
pub fn defineMacro(
    source: []const u8,
    cursor: u32,
    doc_uri: []const u8,
    index: *const WorkspaceIndex,
    allocator: Allocator,
) Allocator.Error!?Location {
    const module = try lish.macro_parser.parseMacroModule(allocator, source);

    for (module.macros) |node| {
        const macro = switch (node) {
            .macro => |m| m,
            .err => continue,
        };

        // Standing on the definition itself (the head name or a parameter):
        // there is nothing to jump to.
        if (macro.id == .valid and contains(macro.id.valid.position, cursor)) return null;
        for (macro.parameters) |param_node| {
            if (param_node == .valid and contains(param_node.valid.position, cursor)) return null;
        }

        if (!contains(macro.body.position, cursor)) continue;
        return resolveInBody(macro, module, cursor, doc_uri, index);
    }
    return null;
}

/// Resolve a cursor known to sit inside `macro`'s body.
fn resolveInBody(
    macro: lish.macro_parser.AstMacro,
    module: lish.macro_parser.AstMacroModule,
    cursor: u32,
    doc_uri: []const u8,
    index: *const WorkspaceIndex,
) ?Location {
    // A scope reference (`:x`) points at the head parameter it names. An
    // unmatched name is an outer binding or unbound: nothing static to resolve.
    if (ast_walk.scopeRefAt(macro.body, cursor)) |ref| {
        const name = ref.body.value_literal.string;
        for (macro.parameters) |param_node| {
            const param = switch (param_node) {
                .valid => |p| p,
                .err => continue,
            };
            if (std.mem.eql(u8, param.id, name))
                return .{ .uri = doc_uri, .start = param.position.start, .end = param.position.end };
        }
        return null;
    }

    // A bare identifier names a macro: a sibling in this module wins (its source
    // is fresher than the index), then the workspace index.
    const target = ast_walk.nodeAt(macro.body, cursor) orelse return null;
    if (!ast_walk.isBareIdentifier(target)) return null;
    const name = target.body.value_literal.string;

    if (siblingMacro(module, name)) |position|
        return .{ .uri = doc_uri, .start = position.start, .end = position.end };
    if (index.lookup(name)) |def|
        return .{ .uri = def.uri, .start = def.start, .end = def.end };
    return null;
}

/// The header position of a macro named `name` defined in `module`, or null.
/// First definition wins, matching the workspace index.
fn siblingMacro(module: lish.macro_parser.AstMacroModule, name: []const u8) ?Position {
    for (module.macros) |node| {
        const macro = switch (node) {
            .macro => |m| m,
            .err => continue,
        };
        const id = switch (macro.id) {
            .valid => |d| d,
            .err => continue,
        };
        if (std.mem.eql(u8, id.name, name)) return id.position;
    }
    return null;
}

fn contains(position: Position, byte: u32) bool {
    return byte >= position.start and byte < position.end;
}

// Tests

const testing = std.testing;

/// An index seeded with one macro defined in `def_uri`, for the resolver tests.
fn indexWith(arena: Allocator, def_uri: []const u8, source: []const u8) !WorkspaceIndex {
    var index = WorkspaceIndex.init(testing.allocator);
    try index.indexSource(arena, def_uri, source);
    return index;
}

test "defineExpression jumps a macro call to its workspace definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = try indexWith(a, "file:///lib.lishmacro", "| double x | * :x 2");
    defer index.deinit();

    // "(double 5)" — cursor on "double" at byte 1.
    const loc = (try defineExpression("(double 5)", 1, &index, a)) orelse return error.NoDef;
    try testing.expectEqualStrings("file:///lib.lishmacro", loc.uri);
    try testing.expectEqual(@as(u32, 2), loc.start); // "double" header id
    try testing.expectEqual(@as(u32, 8), loc.end);
}

test "defineExpression resolves a macro used as an argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = try indexWith(a, "file:///lib.lishmacro", "| helper | 1");
    defer index.deinit();

    // "(f helper)" — "helper" as a bare-identifier argument at byte 3.
    const loc = (try defineExpression("(f helper)", 3, &index, a)) orelse return error.NoDef;
    try testing.expectEqualStrings("file:///lib.lishmacro", loc.uri);
}

test "defineExpression returns null for a builtin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // "+" is a builtin, not a workspace macro.
    try testing.expect((try defineExpression("(+ 1 2)", 1, &index, a)) == null);
}

test "defineExpression returns null on a numeric literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    try testing.expect((try defineExpression("(+ 1 2)", 3, &index, a)) == null);
}

test "defineMacro jumps a scope ref to its head parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // "| double x | * :x 2" — param "x" at byte 9; ":x" body ref names it.
    const source = "| double x | * :x 2";
    const ref_byte: u32 = @intCast(std.mem.indexOf(u8, source, ":x").? + 1); // on the "x"
    const loc = (try defineMacro(source, ref_byte, "file:///m.lishmacro", &index, a)) orelse return error.NoDef;
    try testing.expectEqualStrings("file:///m.lishmacro", loc.uri);
    try testing.expectEqual(@as(u32, 9), loc.start); // the head "x"
    try testing.expectEqual(@as(u32, 10), loc.end);
}

test "defineMacro resolves a body call to a sibling macro in the same module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // "| a x | :x | b y | a :y" — "a" called inside b's body resolves to a's head.
    const source = "| a x | :x | b y | a :y";
    const call_byte: u32 = @intCast(std.mem.lastIndexOfScalar(u8, source, 'a').?); // the call in b's body
    const loc = (try defineMacro(source, call_byte, "file:///m.lishmacro", &index, a)) orelse return error.NoDef;
    try testing.expectEqualStrings("file:///m.lishmacro", loc.uri);
    try testing.expectEqual(@as(u32, 2), loc.start); // a's head id at byte 2
}

test "defineMacro falls back to the workspace index for a cross-file macro" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = try indexWith(a, "file:///other.lishmacro", "| shared | 1");
    defer index.deinit();

    // "| wrap | shared" — "shared" is defined in another file.
    const source = "| wrap | shared";
    const call_byte: u32 = @intCast(std.mem.indexOf(u8, source, "shared").?);
    const loc = (try defineMacro(source, call_byte, "file:///m.lishmacro", &index, a)) orelse return error.NoDef;
    try testing.expectEqualStrings("file:///other.lishmacro", loc.uri);
}

test "defineMacro returns null on the head name itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // Cursor on "double" (byte 2): already at the definition.
    try testing.expect((try defineMacro("| double x | :x", 2, "file:///m.lishmacro", &index, a)) == null);
}

test "defineMacro returns null on a head parameter itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // Cursor on the head "x" (byte 9): already at the definition.
    try testing.expect((try defineMacro("| double x | :x", 9, "file:///m.lishmacro", &index, a)) == null);
}

test "defineMacro returns null for a builtin called in a body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // "*" is a builtin; nothing to jump to.
    const source = "| double x | * :x 2";
    const star_byte: u32 = @intCast(std.mem.indexOfScalar(u8, source, '*').?);
    try testing.expect((try defineMacro(source, star_byte, "file:///m.lishmacro", &index, a)) == null);
}

test "defineMacro returns null for a scope ref with no matching parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    // ":outer" names no head parameter (it would be an outer binding at runtime).
    const source = "| double x | :outer";
    const ref_byte: u32 = @intCast(std.mem.indexOf(u8, source, "outer").?);
    try testing.expect((try defineMacro(source, ref_byte, "file:///m.lishmacro", &index, a)) == null);
}
