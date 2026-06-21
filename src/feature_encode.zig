//! LSP response encoders for hover/completion/signature help/diagnostics.
//! Positions are resolved by the caller, so these are document- and
//! language-agnostic: both lish-lsp and folio-lsp share them.

const std = @import("std");
const server_core = @import("server_core.zig");
const completion = @import("completion.zig");
const signature_help = @import("signature_help.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Position = diagnostics_mod.Position;
const writeJsonString = server_core.writeJsonString;

/// Map a completion kind to an LSP `CompletionItemKind`. Macros share the
/// `Function` icon (LSP has no macro kind); in-scope bindings read as `Variable`.
fn completionKind(kind: completion.Kind) u32 {
    return switch (kind) {
        .keyword => 14, // Keyword
        .function, .macro => 3, // Function
        .variable => 6, // Variable
    };
}

/// `textDocument/hover`: a markdown popup underlining `[start, end)`.
pub fn hover(w: *std.Io.Writer, markdown: []const u8, start: Position, end: Position) !void {
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
    try writeJsonString(w, markdown);
    try w.print(
        "\"}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
        .{ start.line, start.character, end.line, end.character },
    );
}

/// `textDocument/completion`: the item list. Every item replaces the same range
/// `[range_start, range_end)` (the word under the cursor), so a symbolic name
/// like `?<` is replaced wholesale rather than by the client's word heuristics.
pub fn completionList(w: *std.Io.Writer, items: []const completion.Item, range_start: Position, range_end: Position) !void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"label\":\"");
        try writeJsonString(w, item.label);
        try w.print("\",\"kind\":{d},\"insertTextFormat\":2,\"detail\":\"", .{completionKind(item.kind)});
        try writeJsonString(w, item.detail);
        try w.writeAll("\",\"documentation\":\"");
        try writeJsonString(w, item.documentation);
        try w.print(
            "\",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"",
            .{ range_start.line, range_start.character, range_end.line, range_end.character },
        );
        try writeJsonString(w, item.snippet);
        try w.writeAll("\"}}");
    }
    try w.writeByte(']');
}

/// The `diagnostics` array of a `publishDiagnostics` notification. `source`
/// labels the producing server (e.g. "lish", "folio").
pub fn diagnostics(w: *std.Io.Writer, diags: []const diagnostics_mod.Diagnostic, line_table: diagnostics_mod.LineTable, source: []const u8) !void {
    try w.writeByte('[');
    for (diags, 0..) |d, i| {
        if (i != 0) try w.writeByte(',');
        const start = line_table.position(d.start_byte);
        const end = line_table.position(d.end_byte);
        try w.print(
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"{s}\",\"message\":\"",
            .{ start.line, start.character, end.line, end.character, @intFromEnum(d.severity), source },
        );
        try writeJsonString(w, d.message);
        try w.writeAll("\"}");
    }
    try w.writeByte(']');
}

/// `textDocument/signatureHelp`: one signature with its parameters; the client
/// highlights `params[active]` within the label.
pub fn signatureHelp(w: *std.Io.Writer, help: signature_help.Help) !void {
    try w.writeAll("{\"signatures\":[{\"label\":\"");
    try writeJsonString(w, help.label);
    try w.writeAll("\",\"parameters\":[");
    for (help.params, 0..) |param, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"label\":\"");
        try writeJsonString(w, param);
        try w.writeAll("\"}");
    }
    try w.print("]}}],\"activeSignature\":0,\"activeParameter\":{d}}}", .{help.active});
}

const testing = std.testing;

test "hover encodes markdown contents and range" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try hover(&w, "**doc**", .{ .line = 1, .character = 2 }, .{ .line = 1, .character = 7 });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"markdown\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"value\":\"**doc**\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":1,\"character\":2}") != null);
}

test "completionList encodes one item with a shared edit range" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const items = [_]completion.Item{.{
        .label = "map",
        .kind = .function,
        .detail = "binding form",
        .documentation = "",
        .snippet = "map ",
    }};
    try completionList(&w, &items, .{ .line = 0, .character = 1 }, .{ .line = 0, .character = 2 });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"label\":\"map\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"newText\":\"map \"") != null);
}

test "signatureHelp encodes label, params, and active index" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const params = [_][]const u8{ "a", "b" };
    try signatureHelp(&w, .{ .label = "+ a b", .params = &params, .active = 1 });
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"label\":\"+ a b\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"activeParameter\":1") != null);
}
