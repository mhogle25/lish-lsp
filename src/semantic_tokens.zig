//! LSP semantic-tokens encoding driven by the lish highlight oracle.
//!
//! The Highlighter emits non-overlapping byte spans tagged with a Category.
//! We map each Category to an LSP token type, convert byte offsets to
//! line/character via the diagnostics LineTable, and produce LSP's
//! delta-encoded u32 stream.
//!
//! Brackets are intentionally skipped — clients have their own bracket
//! styling and tokenizing them just clutters the layer.

const std = @import("std");
const lish = @import("lish");
const diagnostics_mod = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const Category = lish.highlight.Category;
const LineTable = diagnostics_mod.LineTable;

/// The legend advertised to clients. Index = the value we emit in the token
/// type slot. Names match the LSP standard token type list so clients can
/// theme them without extra mapping work.
pub const TOKEN_TYPES = [_][]const u8{
    "comment", // 0
    "string", // 1
    "number", // 2
    "variable", // 3
    "parameter", // 4
    "operator", // 5
    "keyword", // 6
};

pub const TOKEN_MODIFIERS = [_][]const u8{};

fn categoryToTypeIndex(c: Category) ?u32 {
    return switch (c) {
        .comment => 0,
        .string => 1,
        .number => 2,
        .identifier => 3,
        .scope_ref => 4,
        .sigil => 5,
        .macro_bar => 6,
        .bracket => null,
    };
}

const EmitState = struct {
    prev_line: u32 = 0,
    prev_char: u32 = 0,
};

/// Walk the source with the highlight oracle and return LSP's delta-encoded
/// token stream (5 u32s per token: deltaLine, deltaStartChar, length, type, modifiers).
pub fn encode(source: []const u8, line_table: LineTable, allocator: Allocator) Allocator.Error![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);

    var state = EmitState{};
    var hl = lish.highlight.Highlighter.init(source);
    while (hl.next()) |span| {
        const type_idx = categoryToTypeIndex(span.category) orelse continue;
        const pos = line_table.position(span.start);
        const length = span.end - span.start;

        const delta_line = pos.line - state.prev_line;
        const delta_char = if (delta_line == 0) pos.character - state.prev_char else pos.character;

        try out.appendSlice(allocator, &.{ delta_line, delta_char, length, type_idx, 0 });

        state.prev_line = pos.line;
        state.prev_char = pos.character;
    }
    return out.toOwnedSlice(allocator);
}

test "encode single identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "foo";
    const table = try LineTable.build(source, a);
    const tokens = try encode(source, table, a);

    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 3, 3, 0 }, tokens);
}

test "encode multiple tokens with delta encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "foo 42" — identifier at col 0, number at col 4.
    const source = "foo 42";
    const table = try LineTable.build(source, a);
    const tokens = try encode(source, table, a);

    try std.testing.expectEqual(@as(usize, 10), tokens.len);
    // Identifier "foo" at line 0, char 0, len 3, type variable (3)
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 3, 3, 0 }, tokens[0..5]);
    // Number "42" at line 0, char 4 (delta 4 from prev), len 2, type number (2)
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 2, 2, 0 }, tokens[5..10]);
}

test "encode skips brackets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(foo)" — brackets at 0 and 4, identifier "foo" at 1..4.
    const source = "(foo)";
    const table = try LineTable.build(source, a);
    const tokens = try encode(source, table, a);

    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 3, 0 }, tokens);
}

test "encode across newlines uses absolute char on line change" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "foo\n  42";
    const table = try LineTable.build(source, a);
    const tokens = try encode(source, table, a);

    try std.testing.expectEqual(@as(usize, 10), tokens.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 3, 3, 0 }, tokens[0..5]);
    // Number on line 1 (delta 1), absolute char 2 (because line changed), len 2
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 2, 2, 0 }, tokens[5..10]);
}

test "encode handles scope_ref as parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ":x" — sigil then scope_ref.
    const source = ":x";
    const table = try LineTable.build(source, a);
    const tokens = try encode(source, table, a);

    try std.testing.expectEqual(@as(usize, 10), tokens.len);
    // Sigil ":" at 0, type operator (5)
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 5, 0 }, tokens[0..5]);
    // Scope ref "x" at 1, type parameter (4)
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 1, 4, 0 }, tokens[5..10]);
}

test "encode empty source returns empty slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const table = try LineTable.build("", a);
    const tokens = try encode("", table, a);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}
