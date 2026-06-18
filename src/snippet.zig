//! LSP snippet construction for completion items.
//!
//! A completed call expands to `<name> ${1:p1} ${2:p2} …` so the editor drops
//! the cursor on each parameter in turn. Parameter names are escaped for the
//! snippet grammar (`$`, `}`, `\` are special).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Write the `nth` placeholder ` ${n:param}` (escaped). Callers stream these
/// after writing the name, so they can build from any param representation.
pub fn writePlaceholder(w: *std.Io.Writer, n: usize, param: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(" ${");
    try w.print("{d}:", .{n});
    try writeEscaped(w, param);
    try w.writeByte('}');
}

/// Build the snippet body `name ${1:p1} ${2:p2} …` from ordered parameter names.
/// With no parameters it is just `name` (a plain insert).
pub fn build(allocator: Allocator, name: []const u8, params: []const []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    w.writeAll(name) catch return error.OutOfMemory;
    for (params, 1..) |param, n| {
        writePlaceholder(w, n, param) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '$', '}', '\\' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        }
    }
}

// Tests

const testing = std.testing;

test "build places a numbered placeholder per parameter" {
    const s = try build(testing.allocator, "clamp", &.{ "lo", "hi", "x" });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("clamp ${1:lo} ${2:hi} ${3:x}", s);
}

test "build with no parameters is the bare name" {
    const s = try build(testing.allocator, "now", &.{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("now", s);
}

test "build escapes snippet metacharacters in parameter names" {
    const s = try build(testing.allocator, "fuel", &.{"n|$off"});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("fuel ${1:n|\\$off}", s);
}
