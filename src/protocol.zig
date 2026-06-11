//! LSP message framing over stdio.
//!
//! Each message looks like:
//!     Content-Length: <N>\r\n
//!     [optional other headers]\r\n
//!     \r\n
//!     <N bytes of JSON body>
//!
//! We only read `Content-Length` — other headers are tolerated but ignored.

const std = @import("std");

pub const Error = error{
    EndOfStream,
    MalformedHeader,
    MissingContentLength,
    BodyTooLarge,
} || std.mem.Allocator.Error || std.Io.Reader.Error || std.Io.Writer.Error;

/// Hard cap to bound a single message. LSP messages are usually well under
/// 1 MB; large semanticTokens/full payloads can be bigger but should still
/// fit comfortably. If we hit this in practice, raise it.
pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

/// Read one LSP message from `reader` and return its body as a freshly
/// allocated slice owned by `allocator`. Headers are consumed and discarded.
pub fn readMessage(reader: *std.Io.Reader, allocator: std.mem.Allocator) Error![]u8 {
    var content_length: ?usize = null;

    var header_buf: [256]u8 = undefined;
    while (true) {
        const line = readLine(reader, &header_buf) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.StreamTooLong => return error.MalformedHeader,
            else => |e| return e,
        };
        if (line.len == 0) break; // blank line terminates header block

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const raw = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, raw, 10) catch return error.MalformedHeader;
        }
        // Other headers (Content-Type, etc.) are deliberately ignored.
    }

    const len = content_length orelse return error.MissingContentLength;
    if (len > MAX_BODY_BYTES) return error.BodyTooLarge;

    const body = try allocator.alloc(u8, len);
    try reader.readSliceAll(body);
    return body;
}

/// Write one LSP message: framing header + body, then flush.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) Error!void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

/// Read a single \r\n-terminated line into `buf`, returning a slice over the
/// line content (without the terminator). Returns `StreamTooLong` if the line
/// would exceed `buf`.
fn readLine(reader: *std.Io.Reader, buf: []u8) (Error || error{StreamTooLong})![]u8 {
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.StreamTooLong;
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (i == 0) return error.EndOfStream;
                return error.MalformedHeader;
            },
            else => |e| return e,
        };
        if (byte == '\r') {
            const next = reader.takeByte() catch return error.MalformedHeader;
            if (next != '\n') return error.MalformedHeader;
            return buf[0..i];
        }
        buf[i] = byte;
        i += 1;
    }
}

test "writeMessage frames body with Content-Length" {
    var out_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try writeMessage(&writer, "{\"hello\":\"world\"}");
    try std.testing.expectEqualStrings(
        "Content-Length: 17\r\n\r\n{\"hello\":\"world\"}",
        writer.buffered(),
    );
}

test "readMessage parses a framed message" {
    const input = "Content-Length: 5\r\n\r\nhello";
    var reader = std.Io.Reader.fixed(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try readMessage(&reader, arena.allocator());
    try std.testing.expectEqualStrings("hello", body);
}

test "readMessage tolerates extra headers" {
    const input = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 2\r\n\r\nhi";
    var reader = std.Io.Reader.fixed(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try readMessage(&reader, arena.allocator());
    try std.testing.expectEqualStrings("hi", body);
}

test "readMessage rejects message missing Content-Length" {
    const input = "Content-Type: text/json\r\n\r\nhi";
    var reader = std.Io.Reader.fixed(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingContentLength, readMessage(&reader, arena.allocator()));
}

test "readMessage signals EOF on empty stream" {
    const input = "";
    var reader = std.Io.Reader.fixed(input);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EndOfStream, readMessage(&reader, arena.allocator()));
}
