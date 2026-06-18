//! Minimal `file://` URI <-> filesystem path conversion.
//!
//! LSP speaks document URIs; the workspace scanner speaks filesystem paths.
//! Editors percent-encode paths, so we match that on the way out (and reverse
//! it on the way in) to keep generated URIs aligned with the ones a client
//! sends. This is intentionally small: it assumes absolute POSIX paths under a
//! `file://` (empty authority) scheme and encodes conservatively. Non-file
//! schemes and Windows drive paths are out of scope for v1.

const std = @import("std");
const Allocator = std.mem.Allocator;

const SCHEME = "file://";

/// True for the RFC 3986 unreserved set, plus `/` which we leave intact as the
/// path separator. Everything else is percent-encoded.
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
}

/// Convert an absolute filesystem path to a `file://` URI, percent-encoding any
/// byte outside the unreserved set.
pub fn fromPath(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Exact for an all-unreserved path; a few encoded bytes grow it slightly.
    try out.ensureTotalCapacity(allocator, SCHEME.len + path.len);
    try out.appendSlice(allocator, SCHEME);
    for (path) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &.{ '%', hexDigit(c >> 4), hexDigit(c & 0x0F) });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn fromHex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Convert a `file://` URI back to a filesystem path, decoding `%XX` escapes.
/// Returns null if `uri` is not a `file://` URI. A malformed `%` escape is
/// passed through literally rather than rejected.
pub fn toPath(allocator: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    if (!std.mem.startsWith(u8, uri, SCHEME)) return null;
    const body = uri[SCHEME.len..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Decoding only shrinks (`%XX` -> 1 byte), so the body length is an upper bound.
    try out.ensureTotalCapacity(allocator, body.len);
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '%' and i + 2 < body.len) {
            if (fromHex(body[i + 1])) |hi| {
                if (fromHex(body[i + 2])) |lo| {
                    try out.append(allocator, (hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
        }
        try out.append(allocator, body[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

// Tests

const testing = std.testing;

test "fromPath prefixes the scheme and leaves a plain path intact" {
    const uri = try fromPath(testing.allocator, "/home/u/a.lishmacro");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///home/u/a.lishmacro", uri);
}

test "fromPath percent-encodes spaces and other reserved bytes" {
    const uri = try fromPath(testing.allocator, "/home/my dir/a.lishmacro");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("file:///home/my%20dir/a.lishmacro", uri);
}

test "toPath strips the scheme and decodes escapes" {
    const path = (try toPath(testing.allocator, "file:///home/my%20dir/a.lishmacro")).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/my dir/a.lishmacro", path);
}

test "toPath rejects a non-file URI" {
    try testing.expect((try toPath(testing.allocator, "http://example.com")) == null);
}

test "round trip through encode and decode" {
    const original = "/tmp/weird name (1)/m.lishmacro";
    const uri = try fromPath(testing.allocator, original);
    defer testing.allocator.free(uri);
    const path = (try toPath(testing.allocator, uri)).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(original, path);
}
