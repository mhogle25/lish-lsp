//! `textDocument/hover`: documentation for the name under the cursor.
//!
//! We parse the document, locate the deepest node at the cursor (`ast_walk`),
//! and if it is a bare identifier, resolve it against the registry. A known op
//! or macro yields its signature (and description, for ops) as markdown; string
//! and numeric literals, and unknown names, produce no hover.

const std = @import("std");
const lish = @import("lish");
const ast_walk = @import("ast_walk.zig");
const lish_registry = @import("lish_registry.zig");
const workspace_index = @import("workspace_index.zig");

const Allocator = std.mem.Allocator;
const LishRegistry = lish_registry.LishRegistry;
const WorkspaceIndex = workspace_index.WorkspaceIndex;

pub const Hover = struct {
    /// Markdown body for the hover popup.
    markdown: []const u8,
    /// Byte span of the resolved name, so the client can underline it.
    start: u32,
    end: u32,
};

/// Resolve the hover at byte offset `cursor`, or null if there is nothing to
/// show there. Allocations land in `allocator` (the caller's request arena).
pub fn hoverAt(
    source: []const u8,
    cursor: u32,
    registry: *LishRegistry,
    index: ?*const WorkspaceIndex,
    allocator: Allocator,
) Allocator.Error!?Hover {
    const root = try lish.parser.parse(allocator, source);
    const node = ast_walk.nodeAt(root, cursor) orelse return null;
    return identifierHover(node, registry, index, allocator);
}

/// Resolve the hover at `cursor` in a `.lishmacro` module. Hovering a macro's
/// head name shows its derived signature and docstring; hovering inside a body
/// resolves the name there against the registry, exactly as `hoverAt` does.
pub fn hoverAtMacro(
    source: []const u8,
    cursor: u32,
    registry: *LishRegistry,
    index: ?*const WorkspaceIndex,
    allocator: Allocator,
) Allocator.Error!?Hover {
    const parsed = try lish.macro_parser.parseMacroModuleWithComments(allocator, source);

    for (parsed.module.macros) |node| {
        const macro = switch (node) {
            .macro => |m| m,
            .err => continue,
        };

        // The head name: show the signature we can recover from the head.
        if (macro.id == .valid) {
            const id_data = macro.id.valid;
            if (contains(id_data.position, cursor))
                return .{
                    .markdown = try renderMacroHead(macro, allocator),
                    .start = id_data.position.start,
                    .end = id_data.position.end,
                };
        }

        // Inside the body: same identifier resolution as an expression document.
        if (contains(macro.body.position, cursor)) {
            const inner = ast_walk.nodeAt(macro.body, cursor) orelse return null;
            return identifierHover(inner, registry, index, allocator);
        }
    }
    return null;
}

fn contains(position: lish.ast.Position, byte: u32) bool {
    return byte >= position.start and byte < position.end;
}

/// Shared identifier resolution: a bare-identifier node resolves to its registry
/// entry; on a registry miss it falls back to the workspace index (a user
/// macro); anything else (string, number, error) hovers to nothing.
fn identifierHover(node: *const lish.ast.AstNode, registry: *LishRegistry, index: ?*const WorkspaceIndex, allocator: Allocator) Allocator.Error!?Hover {
    if (node.body != .value_literal) return null;
    if (node.quote != null) return null;
    const value = node.body.value_literal;
    if (value != .string) return null;
    const name = value.string;

    if (try registry.lookup(name)) |symbol| {
        return .{
            .markdown = try renderMarkdown(symbol, allocator),
            .start = node.position.start,
            .end = node.position.end,
        };
    }

    if (index) |idx| {
        if (idx.lookup(name)) |def| {
            return .{
                .markdown = try renderIndexMacro(def, allocator),
                .start = node.position.start,
                .end = node.position.end,
            };
        }
    }

    return null;
}

/// Render a user macro found in the workspace index: its stored signature, its
/// docstring (if any), the file it is defined in, and a file-derived category
/// footnote (mirroring an op's `_operation - arithmetic_`). Matches the head-name
/// hover in the macro's own file, so a cross-file reference reads the same.
fn renderIndexMacro(def: workspace_index.MacroDef, allocator: Allocator) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const basename = uriBasename(def.uri);

    try buf.appendSlice(allocator, "```lish\n");
    try buf.appendSlice(allocator, def.signature);
    try buf.appendSlice(allocator, "\n```");

    if (def.description.len > 0) {
        try buf.appendSlice(allocator, "\n\n");
        try appendDocstring(&buf, allocator, def.description);
    }

    try buf.appendSlice(allocator, "\n\ndefined in `");
    try buf.appendSlice(allocator, basename);
    try buf.appendSlice(allocator, "`\n\n_macro - ");
    try buf.appendSlice(allocator, fileCategory(basename));
    try buf.appendSlice(allocator, "_");
    return buf.toOwnedSlice(allocator);
}

/// The final path segment of a `file://` URI (`.../combat.lishmacro` ->
/// `combat.lishmacro`).
fn uriBasename(uri: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, uri, '/') orelse return uri;
    return uri[slash + 1 ..];
}

/// A macro's category derived from its filename: the basename without the
/// `.lishmacro` extension (`combat.lishmacro` -> `combat`).
fn fileCategory(basename: []const u8) []const u8 {
    if (std.mem.endsWith(u8, basename, lish.MACRO_EXTENSION))
        return basename[0 .. basename.len - lish.MACRO_EXTENSION.len];
    return basename;
}

/// Render a macro head as markdown: the call signature derived from its name and
/// parameters, then its docstring comment (markers stripped), if any.
fn renderMacroHead(macro: lish.macro_parser.AstMacro, allocator: Allocator) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "```lish\n");
    try buf.appendSlice(allocator, macro.id.valid.name);
    for (macro.parameters) |param_node| {
        if (param_node != .valid) continue;
        const param = param_node.valid;
        try buf.appendSlice(allocator, " ");
        if (param.param_type == .deferred) try buf.appendSlice(allocator, "~");
        try buf.appendSlice(allocator, param.id);
    }
    try buf.appendSlice(allocator, "\n```");

    if (macro.description.len > 0) {
        try buf.appendSlice(allocator, "\n\n");
        try appendDocstring(&buf, allocator, macro.description);
    }

    try buf.appendSlice(allocator, "\n\n_macro_");
    return buf.toOwnedSlice(allocator);
}

/// Append a docstring comment run as plain prose: strip each line's leading `#`
/// markers and one following space, and join with spaces.
fn appendDocstring(buf: *std.ArrayList(u8), allocator: Allocator, docstring: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, docstring, '\n');
    var first = true;
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        while (line.len > 0 and line[0] == lish.token.COMMENT) line = line[1..];
        line = std.mem.trimStart(u8, line, " ");
        if (line.len == 0) continue;
        if (!first) try buf.appendSlice(allocator, " ");
        try buf.appendSlice(allocator, line);
        first = false;
    }
}

/// Render a resolved symbol as markdown: a fenced signature, then the
/// description (ops only), then a kind/category footnote.
fn renderMarkdown(symbol: lish_registry.Symbol, allocator: Allocator) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "```lish\n");
    try buf.appendSlice(allocator, symbol.signature);
    try buf.appendSlice(allocator, "\n```");

    if (symbol.description.len > 0) {
        try buf.appendSlice(allocator, "\n\n");
        try buf.appendSlice(allocator, symbol.description);
    }

    switch (symbol.kind) {
        .operation => {
            try buf.appendSlice(allocator, "\n\n_operation");
            if (symbol.category) |category| {
                try buf.appendSlice(allocator, " - ");
                try buf.appendSlice(allocator, category);
            }
            try buf.appendSlice(allocator, "_");
        },
        .macro => try buf.appendSlice(allocator, "\n\n_macro_"),
    }

    return buf.toOwnedSlice(allocator);
}

// Tests

const testing = std.testing;

test "hover on a builtin operator shows its signature and description" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // Cursor on "+" at byte 1 in "(+ 1 2)".
    const hover = (try hoverAt("(+ 1 2)", 1, &registry, null, a)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "```lish") != null);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "_operation") != null);
    try testing.expectEqual(@as(u32, 1), hover.start);
    try testing.expectEqual(@as(u32, 2), hover.end);
}

test "hover on a number yields nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // Cursor on "1" at byte 3.
    try testing.expect((try hoverAt("(+ 1 2)", 3, &registry, null, a)) == null);
}

test "hover on a string literal yields nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // Cursor inside "hi" at byte 4 in "(f \"hi\")".
    try testing.expect((try hoverAt("(f \"hi\")", 4, &registry, null, a)) == null);
}

test "hover on an unknown identifier yields nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    try testing.expect((try hoverAt("(nope)", 1, &registry, null, a)) == null);
}

test "hover falls back to the workspace index for a user macro" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    var index = workspace_index.WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try index.indexSource(a, "file:///home/combat.lishmacro", "## Strikes a target.\n| strike target dmg | :target");

    // "strike" is unknown to the registry but defined in the workspace.
    const hover = (try hoverAt("(strike a b)", 1, &registry, &index, a)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "strike target dmg") != null);
    // The cross-file hover carries the docstring too (markers stripped), matching
    // the head-name hover in the macro's own file.
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "Strikes a target.") != null);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "##") == null);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "defined in `combat.lishmacro`") != null);
    // File-derived category: the basename without the extension.
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "_macro - combat_") != null);
}

test "macro hover on the head name shows its derived signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // "## doubles x\n| double x | * :x 2": cursor on "double" (byte 15).
    const source = "## doubles x\n| double x | * :x 2";
    const hover = (try hoverAtMacro(source, 15, &registry, null, a)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "double x") != null);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "_macro_") != null);
    // Docstring markers are stripped.
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "doubles x") != null);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "##") == null);
}

test "macro hover inside the body resolves a builtin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // "| double x | * :x 2": "*" sits at byte 13.
    const hover = (try hoverAtMacro("| double x | * :x 2", 13, &registry, null, a)) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "_operation") != null);
}

test "macro hover on a parameter yields nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // Cursor on the head parameter "x" at byte 9: not a registry name.
    try testing.expect((try hoverAtMacro("| double x | * :x 2", 9, &registry, null, a)) == null);
}
