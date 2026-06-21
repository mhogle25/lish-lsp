//! In-memory document store keyed by URI.
//!
//! The store owns its keys (URIs) and values (texts), both are duped from
//! whatever transient slice the LSP message body provided, since per-message
//! arenas are reset between messages.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Document = struct {
    text: []u8,
    version: i64,
};

pub const DocumentStore = struct {
    allocator: Allocator,
    map: std.StringHashMapUnmanaged(Document) = .{},

    pub fn init(allocator: Allocator) DocumentStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(store: *DocumentStore) void {
        var it = store.map.iterator();
        while (it.next()) |entry| {
            store.allocator.free(entry.key_ptr.*);
            store.allocator.free(entry.value_ptr.text);
        }
        store.map.deinit(store.allocator);
    }

    /// Insert a document or replace an existing one (didOpen semantics:
    /// the spec treats a second open as an update).
    pub fn open(store: *DocumentStore, uri: []const u8, text: []const u8, version: i64) !void {
        if (store.map.getEntry(uri)) |entry| {
            const new_text = try store.allocator.dupe(u8, text);
            store.allocator.free(entry.value_ptr.text);
            entry.value_ptr.text = new_text;
            entry.value_ptr.version = version;
            return;
        }
        const uri_dup = try store.allocator.dupe(u8, uri);
        errdefer store.allocator.free(uri_dup);
        const text_dup = try store.allocator.dupe(u8, text);
        errdefer store.allocator.free(text_dup);
        try store.map.put(store.allocator, uri_dup, .{ .text = text_dup, .version = version });
    }

    /// Replace the text of an already-open document.
    pub fn replace(store: *DocumentStore, uri: []const u8, text: []const u8, version: i64) !void {
        const entry = store.map.getEntry(uri) orelse return error.DocumentNotFound;
        const new_text = try store.allocator.dupe(u8, text);
        store.allocator.free(entry.value_ptr.text);
        entry.value_ptr.text = new_text;
        entry.value_ptr.version = version;
    }

    pub fn close(store: *DocumentStore, uri: []const u8) void {
        const kv = store.map.fetchRemove(uri) orelse return;
        store.allocator.free(kv.key);
        store.allocator.free(kv.value.text);
    }

    pub fn get(store: *DocumentStore, uri: []const u8) ?Document {
        return store.map.get(uri);
    }

    pub fn count(store: *const DocumentStore) usize {
        return store.map.count();
    }
};

test "open / replace / close round trip" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.lish", "(+ 1 2)", 1);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const doc = store.get("file:///a.lish").?;
    try std.testing.expectEqualStrings("(+ 1 2)", doc.text);
    try std.testing.expectEqual(@as(i64, 1), doc.version);

    try store.replace("file:///a.lish", "(+ 3 4)", 2);
    const updated = store.get("file:///a.lish").?;
    try std.testing.expectEqualStrings("(+ 3 4)", updated.text);
    try std.testing.expectEqual(@as(i64, 2), updated.version);

    store.close("file:///a.lish");
    try std.testing.expectEqual(@as(usize, 0), store.count());
    try std.testing.expect(store.get("file:///a.lish") == null);
}

test "open twice replaces text" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.lish", "first", 1);
    try store.open("file:///a.lish", "second", 2);

    try std.testing.expectEqual(@as(usize, 1), store.count());
    try std.testing.expectEqualStrings("second", store.get("file:///a.lish").?.text);
}

test "replace on missing document errors" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectError(error.DocumentNotFound, store.replace("file:///nope", "x", 1));
}

test "close on missing document is no-op" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    store.close("file:///nope"); // must not crash
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "multiple documents stored independently" {
    var store = DocumentStore.init(std.testing.allocator);
    defer store.deinit();

    try store.open("file:///a.lish", "alpha", 1);
    try store.open("file:///b.lish", "beta", 1);

    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expectEqualStrings("alpha", store.get("file:///a.lish").?.text);
    try std.testing.expectEqualStrings("beta", store.get("file:///b.lish").?.text);

    store.close("file:///a.lish");
    try std.testing.expect(store.get("file:///a.lish") == null);
    try std.testing.expectEqualStrings("beta", store.get("file:///b.lish").?.text);
}
