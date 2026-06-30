//! Walks a lish AST and collects diagnostic spans for LSP publishDiagnostics.
//!
//! The lish parser produces error nodes inline: any subtree may contain an
//! `err` variant or an expression with bracket errors attached. We descend the
//! whole tree and gather every one, then translate byte spans into LSP
//! line/character positions via a precomputed line table.

const std = @import("std");
const lish = @import("lish");
const Allocator = std.mem.Allocator;

const AstNode = lish.ast.AstNode;

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    info = 3,
    hint = 4,
};

pub const Diagnostic = struct {
    start_byte: u32,
    end_byte: u32,
    severity: Severity,
    message: []const u8,
};

/// Walk the AST and append every error node (and bracket error) found.
pub fn collect(node: *const AstNode, out: *std.ArrayList(Diagnostic), allocator: Allocator) Allocator.Error!void {
    switch (node.body) {
        .err => |e| try out.append(allocator, .{
            .start_byte = node.position.start,
            .end_byte = node.position.end,
            .severity = .err,
            .message = e.message,
        }),
        .expression => |expr| {
            if (expr.open_err) |oe| try out.append(allocator, .{
                .start_byte = oe.position.start,
                .end_byte = oe.position.end,
                .severity = .err,
                .message = oe.message,
            });
            if (expr.close_err) |ce| try out.append(allocator, .{
                .start_byte = ce.position.start,
                .end_byte = ce.position.end,
                .severity = .err,
                .message = ce.message,
            });
            try collect(expr.id, out, allocator);
            for (expr.args) |arg| try collect(arg, out, allocator);
        },
        .scope_thunk => |id| try collect(id, out, allocator),
        .value_literal => {},
    }
}

/// Walk a parsed macro module and append every error: module-level parse
/// errors, malformed heads (bad id or parameter), and errors inside each
/// macro's body expression (via `collect`).
pub fn collectMacro(module: lish.macro_parser.AstMacroModule, out: *std.ArrayList(Diagnostic), allocator: Allocator) Allocator.Error!void {
    for (module.macros) |node| {
        switch (node) {
            .err => |e| try out.append(allocator, macroError(e)),
            .macro => |macro| {
                switch (macro.id) {
                    .err => |e| try out.append(allocator, macroError(e)),
                    .valid => {},
                }
                for (macro.parameters) |param| {
                    switch (param) {
                        .err => |e| try out.append(allocator, macroError(e)),
                        .valid => {},
                    }
                }
                try collect(macro.body, out, allocator);
            },
        }
    }
}

fn macroError(e: lish.macro_parser.MacroError) Diagnostic {
    return .{ .start_byte = e.start, .end_byte = e.end, .severity = .err, .message = e.message };
}

/// Maps byte offsets to (line, column) by remembering the byte offset of each
/// line's first byte. Built once per document parse, reused for every span.
pub const LineTable = struct {
    /// Index i holds the byte offset where line i begins. Always has at least
    /// one entry (line 0 starts at byte 0).
    line_starts: []const u32,

    pub fn build(source: []const u8, allocator: Allocator) Allocator.Error!LineTable {
        var starts: std.ArrayList(u32) = .empty;
        try starts.append(allocator, 0);
        for (source, 0..) |c, i| {
            if (c == '\n' and i + 1 <= std.math.maxInt(u32)) {
                try starts.append(allocator, @intCast(i + 1));
            }
        }
        return .{ .line_starts = try starts.toOwnedSlice(allocator) };
    }

    /// Translate a byte offset to {line, character}. `character` here is byte
    /// offset within the line; for ASCII sources this also equals the UTF-16
    /// code-unit offset the LSP spec demands. Non-ASCII source will report
    /// slightly off positions until we add proper UTF-16 counting.
    pub fn position(table: LineTable, byte: u32) Position {
        var lo: usize = 0;
        var hi: usize = table.line_starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (table.line_starts[mid] <= byte) lo = mid + 1 else hi = mid;
        }
        const line_index: u32 = @intCast(lo - 1);
        const col = byte - table.line_starts[line_index];
        return .{ .line = line_index, .character = col };
    }

    /// Translate an LSP {line, character} back to a byte offset. The inverse of
    /// `position`. A line past the end clamps to the last line's start, and (as
    /// with `position`) `character` is treated as a byte column, which matches
    /// for ASCII source. Out-of-range columns are not clamped to the line end:
    /// the caller checks the result against the document length.
    pub fn byteAt(table: LineTable, line: u32, character: u32) u32 {
        const line_index = if (line < table.line_starts.len) line else @as(u32, @intCast(table.line_starts.len - 1));
        return table.line_starts[line_index] + character;
    }
};

pub const Position = struct {
    line: u32,
    character: u32,
};

test "collect finds top-level syntax error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try lish.parser.parse(a, "(+ 1 2");
    var diags: std.ArrayList(Diagnostic) = .empty;
    try collect(root, &diags, a);

    try std.testing.expect(diags.items.len >= 1);
}

test "collect finds bracket errors on expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try lish.parser.parse(a, "+ 1 2)");
    var diags: std.ArrayList(Diagnostic) = .empty;
    try collect(root, &diags, a);

    try std.testing.expect(diags.items.len >= 1);
}

test "collect finds nothing for valid input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try lish.parser.parse(a, "(+ 1 2)");
    var diags: std.ArrayList(Diagnostic) = .empty;
    try collect(root, &diags, a);

    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "collectMacro finds a malformed-head error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A bare `~` with no parameter name is a head error.
    const module = try lish.macro_parser.parseMacroModule(a, "foo ~ | :foo ;");
    var diags: std.ArrayList(Diagnostic) = .empty;
    try collectMacro(module, &diags, a);
    try std.testing.expect(diags.items.len >= 1);
}

test "collectMacro finds a body error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Unbalanced bracket inside the body.
    const module = try lish.macro_parser.parseMacroModule(a, "foo x | (+ :x 1 ;");
    var diags: std.ArrayList(Diagnostic) = .empty;
    try collectMacro(module, &diags, a);
    try std.testing.expect(diags.items.len >= 1);
}

test "collectMacro finds nothing for a valid module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module = try lish.macro_parser.parseMacroModule(a, "double x | * :x 2 ;");
    var diags: std.ArrayList(Diagnostic) = .empty;
    try collectMacro(module, &diags, a);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "LineTable maps byte offsets correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "abc\ndef\n\nghi";
    const table = try LineTable.build(source, arena.allocator());

    try std.testing.expectEqual(@as(usize, 4), table.line_starts.len);

    // line 0: "abc" at bytes 0..3
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, table.position(0));
    try std.testing.expectEqual(Position{ .line = 0, .character = 2 }, table.position(2));

    // line 1: "def" at bytes 4..7
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, table.position(4));
    try std.testing.expectEqual(Position{ .line = 1, .character = 2 }, table.position(6));

    // line 2: empty
    try std.testing.expectEqual(Position{ .line = 2, .character = 0 }, table.position(8));

    // line 3: "ghi" at bytes 9..12
    try std.testing.expectEqual(Position{ .line = 3, .character = 0 }, table.position(9));
    try std.testing.expectEqual(Position{ .line = 3, .character = 2 }, table.position(11));
}

test "LineTable handles single-line source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const table = try LineTable.build("hello", arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), table.line_starts.len);
    try std.testing.expectEqual(Position{ .line = 0, .character = 4 }, table.position(4));
}

test "LineTable handles empty source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const table = try LineTable.build("", arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), table.line_starts.len);
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, table.position(0));
}
