//! `textDocument/completion`: vocabulary-name completion.
//!
//! This first pass completes *callable names* — builtins, stdlib/host macros,
//! and workspace macros (from the go-to-definition index) — filtered by the word
//! prefix under the cursor. Each item carries its kind (keyword/function/macro),
//! the call signature as detail, and the description as documentation.
//!
//! Resolution is pure byte scanning, no parse: the word prefix is the run of
//! identifier bytes ending at the cursor, and completion is suppressed inside a
//! string or comment and immediately after a `:`/`~` (scope references and
//! deferred parameters are a separate, not-yet-built feature). Working off raw
//! bytes keeps completion robust while the surrounding expression is mid-edit
//! and not yet parseable.

const std = @import("std");
const lish = @import("lish");
const lish_registry = @import("lish_registry.zig");
const workspace_index = @import("workspace_index.zig");

const Allocator = std.mem.Allocator;
const LishRegistry = lish_registry.LishRegistry;
const WorkspaceIndex = workspace_index.WorkspaceIndex;
const token = lish.token;

/// A completion suggestion. `kind` mirrors the operator classification; the
/// server maps it to an LSP `CompletionItemKind`.
pub const Item = struct {
    label: []const u8,
    kind: lish_registry.OperatorClass,
    detail: []const u8,
    documentation: []const u8,
};

/// The completions for a request, plus the byte offset where the replaced word
/// begins (the server turns `[replace_start, cursor)` into the edit range so a
/// symbolic name like `?<` is replaced wholesale rather than by the client's
/// own word heuristics).
pub const Result = struct {
    items: []const Item,
    replace_start: u32,
};

/// Compute the completions at byte offset `cursor`, or null if completion should
/// not fire here (inside a string/comment, or right after a `:`/`~`).
pub fn collect(
    source: []const u8,
    cursor: u32,
    registry: *LishRegistry,
    index: ?*const WorkspaceIndex,
    allocator: Allocator,
) Allocator.Error!?Result {
    if (inStringOrComment(source, cursor)) return null;

    const replace_start = wordStart(source, cursor);

    // A word behind a `:` is a scope reference and behind a `~` a deferred
    // parameter: neither is a vocabulary position.
    if (replace_start > 0) {
        const before = source[replace_start - 1];
        if (before == token.SCOPE_THUNK or before == token.DEFERRED) return null;
    }

    const prefix = source[replace_start..cursor];

    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(allocator);

    var candidates: std.ArrayListUnmanaged(LishRegistry.Candidate) = .empty;
    defer candidates.deinit(allocator);
    try registry.collectMatching(prefix, &candidates, allocator);

    // Track names already offered so a workspace macro that shadows a vocabulary
    // name is not listed twice (vocabulary wins).
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (candidates.items) |candidate| {
        try seen.put(allocator, candidate.name, {});
        try items.append(allocator, .{
            .label = candidate.name,
            .kind = candidate.class,
            .detail = candidate.detail,
            .documentation = candidate.documentation,
        });
    }

    if (index) |idx| {
        var it = idx.map.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            if (seen.contains(name)) continue;
            try seen.put(allocator, name, {});
            try items.append(allocator, .{
                .label = name,
                .kind = .macro,
                .detail = entry.value_ptr.signature,
                .documentation = "",
            });
        }
    }

    return .{ .items = try items.toOwnedSlice(allocator), .replace_start = replace_start };
}

/// The start of the identifier-byte run ending at `cursor`. Equal to `cursor`
/// when the character before the cursor is a delimiter (an empty prefix).
fn wordStart(source: []const u8, cursor: u32) u32 {
    var start = cursor;
    while (start > 0 and isIdentByte(source[start - 1])) start -= 1;
    return start;
}

/// True for a byte that can appear in a lish identifier/operator name: anything
/// that is not whitespace, a control byte, a reserved delimiter, or `#`.
fn isIdentByte(c: u8) bool {
    if (c <= ' ') return false; // space and all control bytes
    if (c == token.COMMENT) return false;
    return !token.isReservedChar(c);
}

/// Whether `cursor` sits inside a string literal or a line comment. lish strings
/// are single-line and comments run to end of line, so scanning the current line
/// up to the cursor fully determines the context.
fn inStringOrComment(source: []const u8, cursor: u32) bool {
    var line_start = cursor;
    while (line_start > 0 and source[line_start - 1] != token.NEWLINE) line_start -= 1;

    var in_string = false;
    var quote: u8 = 0;
    var i = line_start;
    while (i < cursor) : (i += 1) {
        const c = source[i];
        if (in_string) {
            if (c == token.BACKSLASH) {
                i += 1; // skip the escaped byte
                continue;
            }
            if (c == quote) in_string = false;
        } else {
            if (c == token.COMMENT) return true; // comment runs to end of line
            if (c == token.QUOTE_DOUBLE or c == token.QUOTE_SINGLE) {
                in_string = true;
                quote = c;
            }
        }
    }
    return in_string;
}

// Tests

const testing = std.testing;

fn labels(result: Result, allocator: Allocator) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, result.items.len);
    for (result.items, 0..) |item, i| out[i] = item.label;
    return out;
}

fn contains(result: Result, name: []const u8) bool {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, name)) return true;
    }
    return false;
}

test "completes a builtin prefix in operator position" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // "(ma" — cursor at end, prefix "ma".
    const result = (try collect("(ma", 3, &registry, null, a)) orelse return error.NoCompletion;
    try testing.expectEqual(@as(u32, 1), result.replace_start); // after "("
    try testing.expect(contains(result, "map"));
    try testing.expect(contains(result, "max"));
    // Everything offered matches the prefix.
    for (result.items) |item| try testing.expect(std.mem.startsWith(u8, item.label, "ma"));
}

test "completes after a single-term sigil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // "$no" — single-term call prefix "no".
    const result = (try collect("$no", 3, &registry, null, a)) orelse return error.NoCompletion;
    try testing.expectEqual(@as(u32, 1), result.replace_start);
    try testing.expect(std.mem.startsWith(u8, result.items[0].label, "no"));
}

test "suppresses completion immediately after a scope thunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // ":ma" is a scope reference, not a vocabulary position.
    try testing.expect((try collect(":ma", 3, &registry, null, a)) == null);
}

test "suppresses completion inside a string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // Cursor inside the open string literal.
    try testing.expect((try collect("(f \"ma", 6, &registry, null, a)) == null);
}

test "suppresses completion inside a comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    try testing.expect((try collect("# ma", 4, &registry, null, a)) == null);
}

test "empty prefix after an open paren offers the vocabulary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    const result = (try collect("(", 1, &registry, null, a)) orelse return error.NoCompletion;
    try testing.expectEqual(@as(u32, 1), result.replace_start);
    try testing.expect(result.items.len > 50); // the whole vocabulary
    try testing.expect(contains(result, "if"));
}

test "includes a workspace macro and dedupes against the vocabulary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    var index = WorkspaceIndex.init(testing.allocator);
    defer index.deinit();
    try index.indexSource(a, "file:///lib.lishmacro", "| myhelper x | :x");

    const result = (try collect("(my", 3, &registry, &index, a)) orelse return error.NoCompletion;
    try testing.expect(contains(result, "myhelper"));

    // No label appears twice.
    for (result.items, 0..) |item, i| {
        for (result.items[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, item.label, other.label));
        }
    }
}

test "symbolic operator name is part of the prefix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var registry = try LishRegistry.init(a);
    defer registry.deinit();

    // "(?" — prefix "?" should reach the random ops "?" and "?<".
    const result = (try collect("(?", 2, &registry, null, a)) orelse return error.NoCompletion;
    try testing.expectEqual(@as(u32, 1), result.replace_start);
    try testing.expect(contains(result, "?"));
    try testing.expect(contains(result, "?<"));
}
