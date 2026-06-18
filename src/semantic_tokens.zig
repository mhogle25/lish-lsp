//! LSP semantic-tokens encoding driven by the parse tree and the registry.
//!
//! We parse the document (retaining comment spans), walk the AST into
//! role-tagged spans (`ast_walk`), and resolve each operator against the
//! server's registry so builtins, macros, and keywords get distinct token
//! types. Comment spans, which live outside the AST, are folded back in. The
//! merged, source-ordered spans become LSP's delta-encoded u32 stream.
//!
//! This replaces the older line-level highlight oracle: the tree tells us a
//! node's *role* (callable vs argument vs scope reference), and the registry
//! tells us what a callable actually *is*. Brackets are omitted; clients style
//! those themselves.

const std = @import("std");
const lish = @import("lish");
const ast_walk = @import("ast_walk.zig");
const macro_walk = @import("macro_walk.zig");
const diagnostics_mod = @import("diagnostics.zig");
const lish_registry = @import("lish_registry.zig");
const workspace_index = @import("workspace_index.zig");

const Allocator = std.mem.Allocator;
const LineTable = diagnostics_mod.LineTable;
const LishRegistry = lish_registry.LishRegistry;
const WorkspaceIndex = workspace_index.WorkspaceIndex;
const Role = ast_walk.Role;

/// The legend advertised to clients. Index = the value emitted in the token-type
/// slot. Names are LSP-standard so themes pick them up without extra mapping.
pub const TOKEN_TYPES = [_][]const u8{
    "comment", // 0
    "string", // 1
    "number", // 2
    "variable", // 3
    "parameter", // 4
    "operator", // 5
    "function", // 6
    "macro", // 7
    "keyword", // 8
};

pub const TOKEN_MODIFIERS = [_][]const u8{};

const TYPE_COMMENT = 0;
const TYPE_STRING = 1;
const TYPE_NUMBER = 2;
const TYPE_VARIABLE = 3;
const TYPE_PARAMETER = 4;
const TYPE_OPERATOR = 5;
const TYPE_FUNCTION = 6;
const TYPE_MACRO = 7;
const TYPE_KEYWORD = 8;

/// A resolved token before delta-encoding: an absolute byte span plus its LSP
/// token-type index.
const Token = struct {
    start: u32,
    end: u32,
    type_index: u32,
};

fn lessByStart(_: void, a: Token, b: Token) bool {
    return a.start < b.start;
}

/// Map a structural role to an LSP token type. Operators consult the registry:
/// a keyword-category builtin reads as a keyword, other builtins as functions,
/// stdlib/host macros as macros, and anything unknown as a plain variable (so an
/// undefined call is visually distinct from a real one).
fn typeForRole(role: Role, source: []const u8, span: ast_walk.RoleSpan, registry: *const LishRegistry, index: ?*const WorkspaceIndex) u32 {
    return switch (role) {
        .string => TYPE_STRING,
        .number => TYPE_NUMBER,
        .identifier => TYPE_VARIABLE,
        .scope_ref, .parameter => TYPE_PARAMETER,
        .sigil => TYPE_OPERATOR,
        .definition => TYPE_FUNCTION,
        .operator => operatorType(source[span.start..span.end], registry, index),
    };
}

/// Classify a callable name. A name the registry does not know but the workspace
/// index does is a user macro (so it reads as `macro`, not an undefined
/// `variable`); a name neither knows stays a `variable`.
fn operatorType(name: []const u8, registry: *const LishRegistry, index: ?*const WorkspaceIndex) u32 {
    return switch (registry.classifyOperator(name)) {
        .keyword => TYPE_KEYWORD,
        .function => TYPE_FUNCTION,
        .macro => TYPE_MACRO,
        .unknown => if (index) |idx|
            (if (idx.lookup(name) != null) TYPE_MACRO else TYPE_VARIABLE)
        else
            TYPE_VARIABLE,
    };
}

/// Which lish grammar a document follows. A `.lishmacro` file is a module of
/// macro definitions; everything else is an expression document.
pub const Language = enum { expression, macro };

/// Parse `source`, walk it, and return LSP's delta-encoded token stream (5 u32s
/// per token: deltaLine, deltaStartChar, length, type, modifiers).
pub fn encode(
    source: []const u8,
    line_table: LineTable,
    registry: *const LishRegistry,
    index: ?*const WorkspaceIndex,
    language: Language,
    allocator: Allocator,
) Allocator.Error![]u32 {
    var role_spans: []const ast_walk.RoleSpan = undefined;
    var comments: []const lish.token.CommentSpan = undefined;
    switch (language) {
        .expression => {
            const parsed = try lish.parser.parseWithComments(allocator, source);
            role_spans = try ast_walk.collect(parsed.root, allocator);
            comments = parsed.comments;
        },
        .macro => {
            const parsed = try lish.macro_parser.parseMacroModuleWithComments(allocator, source);
            role_spans = try macro_walk.collect(parsed.module, source, allocator);
            comments = parsed.comments;
        },
    }

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);

    for (role_spans) |span| {
        try tokens.append(allocator, .{
            .start = span.start,
            .end = span.end,
            .type_index = typeForRole(span.role, source, span, registry, index),
        });
    }
    for (comments) |comment| {
        try tokens.append(allocator, .{ .start = comment.start, .end = comment.end, .type_index = TYPE_COMMENT });
    }

    std.mem.sort(Token, tokens.items, {}, lessByStart);

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);

    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    for (tokens.items) |token| {
        const pos = line_table.position(token.start);
        const length = token.end - token.start;

        const delta_line = pos.line - prev_line;
        const delta_char = if (delta_line == 0) pos.character - prev_char else pos.character;

        try out.appendSlice(allocator, &.{ delta_line, delta_char, length, token.type_index, 0 });

        prev_line = pos.line;
        prev_char = pos.character;
    }
    return out.toOwnedSlice(allocator);
}

// Tests

const testing = std.testing;

/// Encode an expression document against a freshly built standard registry and
/// no workspace index.
fn encodeStd(source: []const u8, allocator: Allocator) ![]u32 {
    var registry = try LishRegistry.init(allocator);
    defer registry.deinit();
    const table = try LineTable.build(source, allocator);
    return encode(source, table, &registry, null, .expression, allocator);
}

/// Encode a macro-module document against a freshly built standard registry and
/// no workspace index.
fn encodeMacroStd(source: []const u8, allocator: Allocator) ![]u32 {
    var registry = try LishRegistry.init(allocator);
    defer registry.deinit();
    const table = try LineTable.build(source, allocator);
    return encode(source, table, &registry, null, .macro, allocator);
}

test "operator resolves to function via the registry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(+ 1 2)" -> "+" is a builtin (function), then two numbers.
    const tokens = try encodeStd("(+ 1 2)", a);
    try testing.expectEqual(@as(usize, 15), tokens.len);
    // "+" at char 1: function (6)
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, TYPE_FUNCTION, 0 }, tokens[0..5]);
    // "1" at char 3 (delta 2): number (2)
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1, TYPE_NUMBER, 0 }, tokens[5..10]);
    // "2" at char 5 (delta 2): number (2)
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1, TYPE_NUMBER, 0 }, tokens[10..15]);
}

test "keyword-category builtin resolves to keyword" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(if x)" -> "if" is in the control category: keyword.
    const tokens = try encodeStd("(if x)", a);
    try testing.expectEqual(@as(usize, 10), tokens.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, TYPE_KEYWORD, 0 }, tokens[0..5]);
    // "x" is an unknown identifier in argument position: variable (3).
    try testing.expectEqualSlices(u32, &.{ 0, 3, 1, TYPE_VARIABLE, 0 }, tokens[5..10]);
}

test "unknown operator reads as a variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = try encodeStd("(nope 1)", a);
    // "nope" at char 1, len 4: not a known op -> variable (3).
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, TYPE_VARIABLE, 0 }, tokens[0..5]);
}

test "operator unknown to the registry but in the index reads as a macro" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try index.indexSource(a, "file:///lib.lishmacro", "| myMacro x | :x");

    const table = try LineTable.build("(myMacro 1)", a);
    const tokens = try encode("(myMacro 1)", table, &registry, &index, .expression, a);
    // "myMacro" at char 1, length 7: not a builtin, but the index knows it -> macro (7).
    try testing.expectEqualSlices(u32, &.{ 0, 1, 7, TYPE_MACRO, 0 }, tokens[0..5]);
}

test "operator unknown to both registry and index stays a variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();

    const table = try LineTable.build("(nope 1)", a);
    const tokens = try encode("(nope 1)", table, &registry, &index, .expression, a);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, TYPE_VARIABLE, 0 }, tokens[0..5]);
}

test "string literal versus bare identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(cat \"hi\" bye)" -> string then identifier.
    const tokens = try encodeStd("(cat \"hi\" bye)", a);
    try testing.expectEqual(@as(usize, 15), tokens.len);
    // "hi" string spans char 5..9, length 4 (quotes included): string (1).
    try testing.expectEqualSlices(u32, &.{ 0, 4, 4, TYPE_STRING, 0 }, tokens[5..10]);
    // "bye" identifier: variable (3).
    try testing.expectEqualSlices(u32, &.{ 0, 5, 3, TYPE_VARIABLE, 0 }, tokens[10..15]);
}

test "comment span folded in alongside ast tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "## hi\n(+ 1 2)" -> comment on line 0, then the expression on line 1.
    const tokens = try encodeStd("## hi\n(+ 1 2)", a);
    // First token is the comment at line 0, char 0, length 5.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 5, TYPE_COMMENT, 0 }, tokens[0..5]);
    // Next is "+" on line 1 (delta 1), char 1.
    try testing.expectEqualSlices(u32, &.{ 1, 1, 1, TYPE_FUNCTION, 0 }, tokens[5..10]);
}

test "scope ref emits sigil then parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(when :hp)" -> keyword "when", operator ":", parameter "hp".
    const tokens = try encodeStd("(when :hp)", a);
    try testing.expectEqual(@as(usize, 15), tokens.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, TYPE_KEYWORD, 0 }, tokens[0..5]);
    try testing.expectEqualSlices(u32, &.{ 0, 5, 1, TYPE_OPERATOR, 0 }, tokens[5..10]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, TYPE_PARAMETER, 0 }, tokens[10..15]);
}

test "macro module: head definition and parameter, registry-aware body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "| double x | * :x 2"
    const tokens = try encodeMacroStd("| double x | * :x 2", a);
    // definition "double" at char 2, length 6: function (6).
    try testing.expectEqualSlices(u32, &.{ 0, 2, 6, TYPE_FUNCTION, 0 }, tokens[0..5]);
    // parameter "x" at char 9 (delta 7), length 1: parameter (4).
    try testing.expectEqualSlices(u32, &.{ 0, 7, 1, TYPE_PARAMETER, 0 }, tokens[5..10]);
    // body "*" is a builtin: function (6). Token 2's type slot is index 13.
    try testing.expectEqual(@as(u32, TYPE_FUNCTION), tokens[13]);
}

test "macro module folds in a leading docstring comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = try encodeMacroStd("## doc\n| id x | :x", a);
    // First token is the comment on line 0.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 6, TYPE_COMMENT, 0 }, tokens[0..5]);
}

test "empty source returns no tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = try encodeStd("", a);
    try testing.expectEqual(@as(usize, 0), tokens.len);
}
