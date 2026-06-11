//! LSP server state machine + method dispatch.
//!
//! Tracks the protocol lifecycle (uninitialized → initialized → shutdown → exit),
//! gates which methods may run in each state, and emits JSON-RPC responses through
//! the supplied writer.

const std = @import("std");
const lish = @import("lish");
const protocol = @import("protocol.zig");
const document_store = @import("document_store.zig");
const diagnostics_mod = @import("diagnostics.zig");
const semantic_tokens = @import("semantic_tokens.zig");

pub const DocumentStore = document_store.DocumentStore;
pub const Document = document_store.Document;

pub const State = enum {
    uninitialized,
    initialized,
    shutdown,
};

/// Standard JSON-RPC error codes that we emit.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
};

pub const Server = struct {
    state: State = .uninitialized,
    /// Set true when the server should exit cleanly (received `exit` after `shutdown`).
    should_exit: bool = false,
    /// Set true when exit was received without a prior shutdown — caller should
    /// terminate with a nonzero status per LSP spec.
    exit_was_unclean: bool = false,
    writer: *std.Io.Writer,
    log: *std.Io.Writer,
    documents: DocumentStore,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, log: *std.Io.Writer) Server {
        return .{
            .writer = writer,
            .log = log,
            .documents = DocumentStore.init(allocator),
        };
    }

    pub fn deinit(server: *Server) void {
        server.documents.deinit();
    }

    /// Parse and dispatch one LSP message. `body` is the JSON payload (no framing).
    /// `arena` is reset by the caller between calls.
    pub fn handle(server: *Server, body: []const u8, arena: std.mem.Allocator) !void {
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| {
            server.log.print("lish-lsp: parse error: {s}\n", .{@errorName(err)}) catch {};
            server.log.flush() catch {};
            return; // notifications can't be answered with errors and we can't recover the id
        };

        if (root != .object) return;
        const method_val = root.object.get("method") orelse return;
        if (method_val != .string) return;
        const method = method_val.string;
        const id = root.object.get("id"); // null for notifications

        return server.dispatch(method, id, root.object.get("params"));
    }

    fn dispatch(server: *Server, method: []const u8, id: ?std.json.Value, params: ?std.json.Value) !void {
        // Lifecycle gating.
        if (server.state == .uninitialized and !std.mem.eql(u8, method, "initialize") and !std.mem.eql(u8, method, "exit")) {
            if (id) |req_id| try server.sendError(req_id, .server_not_initialized, "server not initialized");
            return;
        }
        if (server.state == .shutdown and !std.mem.eql(u8, method, "exit")) {
            if (id) |req_id| try server.sendError(req_id, .invalid_request, "server has shut down");
            return;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            const req_id = id orelse return; // initialize must be a request
            try server.handleInitialize(req_id);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // Notification — no response. State already moved on the initialize response.
        } else if (std.mem.eql(u8, method, "shutdown")) {
            const req_id = id orelse return;
            server.state = .shutdown;
            try server.sendResult(req_id, "null");
        } else if (std.mem.eql(u8, method, "exit")) {
            server.should_exit = true;
            server.exit_was_unclean = server.state != .shutdown;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            server.handleDidOpen(params) catch |err| {
                server.log.print("lish-lsp: didOpen failed: {s}\n", .{@errorName(err)}) catch {};
                server.log.flush() catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            server.handleDidChange(params) catch |err| {
                server.log.print("lish-lsp: didChange failed: {s}\n", .{@errorName(err)}) catch {};
                server.log.flush() catch {};
            };
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            server.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            const req_id = id orelse return;
            try server.handleSemanticTokensFull(req_id, params);
        } else {
            // Unknown method. Per spec, requests get an error; notifications silently ignored.
            if (id) |req_id| try server.sendError(req_id, .method_not_found, "method not supported");
        }
    }

    fn handleDidOpen(server: *Server, params: ?std.json.Value) !void {
        const td = textDocumentOf(params) orelse return;
        const uri = stringField(td, "uri") orelse return;
        const text = stringField(td, "text") orelse return;
        const version = versionField(td);
        try server.documents.open(uri, text, version);
        try server.publishDiagnostics(uri);
    }

    fn handleDidChange(server: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        if (p != .object) return;
        const td = p.object.get("textDocument") orelse return;
        if (td != .object) return;
        const uri = stringField(td.object, "uri") orelse return;
        const version = versionField(td.object);

        const changes_val = p.object.get("contentChanges") orelse return;
        if (changes_val != .array) return;
        const changes = changes_val.array.items;
        if (changes.len == 0) return;

        // We advertised full sync (kind 1) — take the last change's `text`.
        const last = changes[changes.len - 1];
        if (last != .object) return;
        const text_val = last.object.get("text") orelse return;
        if (text_val != .string) return;

        try server.documents.replace(uri, text_val.string, version);
        try server.publishDiagnostics(uri);
    }

    /// Parse the document and emit a publishDiagnostics notification.
    /// Always emits — even an empty diagnostic list, so the editor clears
    /// stale errors from a previous parse.
    fn publishDiagnostics(server: *Server, uri: []const u8) !void {
        const doc = server.documents.get(uri) orelse return;

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const root = try lish.parser.parse(a, doc.text);
        var diags: std.ArrayList(diagnostics_mod.Diagnostic) = .empty;
        try diagnostics_mod.collect(root, &diags, a);

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);

        // Build the notification body. We do this in a growable buffer because
        // diagnostic count + message length are unbounded.
        var body: std.Io.Writer.Allocating = .init(a);
        const bw = &body.writer;

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try writeJsonString(bw, uri);
        try bw.print("\",\"version\":{d},\"diagnostics\":[", .{doc.version});

        for (diags.items, 0..) |d, i| {
            if (i != 0) try bw.writeByte(',');
            const start = line_table.position(d.start_byte);
            const end = line_table.position(d.end_byte);
            try bw.print(
                "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"lish\",\"message\":\"",
                .{ start.line, start.character, end.line, end.character, @intFromEnum(d.severity) },
            );
            try writeJsonString(bw, d.message);
            try bw.writeAll("\"}");
        }

        try bw.writeAll("]}}");

        try protocol.writeMessage(server.writer, body.written());
    }

    fn handleDidClose(server: *Server, params: ?std.json.Value) void {
        const td = textDocumentOf(params) orelse return;
        const uri = stringField(td, "uri") orelse return;
        server.documents.close(uri);
    }

    fn handleInitialize(server: *Server, id: std.json.Value) !void {
        server.state = .initialized;

        var buf: [2048]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        try bw.writeAll("{\"capabilities\":{\"textDocumentSync\":1,\"positionEncoding\":\"utf-16\",\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[");
        inline for (semantic_tokens.TOKEN_TYPES, 0..) |name, i| {
            if (i != 0) try bw.writeByte(',');
            try bw.print("\"{s}\"", .{name});
        }
        try bw.writeAll("],\"tokenModifiers\":[]},\"full\":true}},\"serverInfo\":{\"name\":\"lish-lsp\",\"version\":\"0.0.0\"}}");
        try server.sendResult(id, bw.buffered());
    }

    fn handleSemanticTokensFull(server: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const td = textDocumentOf(params) orelse {
            try server.sendResult(id, "null");
            return;
        };
        const uri = stringField(td, "uri") orelse {
            try server.sendResult(id, "null");
            return;
        };
        const doc = server.documents.get(uri) orelse {
            try server.sendResult(id, "null");
            return;
        };

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);
        const data = try semantic_tokens.encode(doc.text, line_table, a);

        var body: std.Io.Writer.Allocating = .init(a);
        const bw = &body.writer;
        try bw.writeAll("{\"data\":[");
        for (data, 0..) |v, i| {
            if (i != 0) try bw.writeByte(',');
            try bw.print("{d}", .{v});
        }
        try bw.writeAll("]}");
        try server.sendResult(id, body.written());
    }

    /// Emit a success response: `{"jsonrpc":"2.0","id":<id>,"result":<result_json>}`.
    /// `result_json` is a raw JSON fragment (e.g. `"null"` or an object literal).
    fn sendResult(server: *Server, id: std.json.Value, result_json: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeIdValue(&bw, id);
        try bw.writeAll(",\"result\":");
        try bw.writeAll(result_json);
        try bw.writeAll("}");
        try protocol.writeMessage(server.writer, bw.buffered());
    }

    fn sendError(server: *Server, id: std.json.Value, code: ErrorCode, message: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeIdValue(&bw, id);
        try bw.print(",\"error\":{{\"code\":{d},\"message\":\"", .{@intFromEnum(code)});
        try writeJsonString(&bw, message);
        try bw.writeAll("\"}}");
        try protocol.writeMessage(server.writer, bw.buffered());
    }
};

fn textDocumentOf(params: ?std.json.Value) ?std.json.ObjectMap {
    const p = params orelse return null;
    if (p != .object) return null;
    const td = p.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    return td.object;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn versionField(obj: std.json.ObjectMap) i64 {
    const v = obj.get("version") orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

/// Echo an id back as a JSON value. The spec allows string, integer, or null.
fn writeIdValue(w: *std.Io.Writer, id: std.json.Value) !void {
    switch (id) {
        .string => |s| {
            try w.writeAll("\"");
            try writeJsonString(w, s);
            try w.writeAll("\"");
        },
        .integer => |i| try w.print("{d}", .{i}),
        .number_string => |s| try w.writeAll(s),
        .null => try w.writeAll("null"),
        else => try w.writeAll("null"),
    }
}

/// Write `s` as the inner bytes of a JSON string literal (no surrounding quotes).
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
}

test "initialize transitions state and emits capabilities" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
    try server.handle(request, arena.allocator());

    try std.testing.expectEqual(State.initialized, server.state);
    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"textDocumentSync\":1") != null);
}

test "shutdown then exit sets clean exit" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\"}", arena.allocator());
    try std.testing.expectEqual(State.shutdown, server.state);

    try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}", arena.allocator());
    try std.testing.expect(server.should_exit);
    try std.testing.expect(!server.exit_was_unclean);
}

test "exit without shutdown is unclean" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}", arena.allocator());
    try std.testing.expect(server.should_exit);
    try std.testing.expect(server.exit_was_unclean);
}

test "request before initialize returns server_not_initialized" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\"}", arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":-32002") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":2") != null);
}

test "unknown method after initialize returns method_not_found" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":\"x9\",\"method\":\"bogus/method\"}", arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"x9\"") != null);
}

test "string ids are echoed back" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\"}", arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":\"abc\"") != null);
}

test "notifications without id produce no response" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":1}}", arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), out_writer.buffered().len);
}

test "didOpen, didChange, didClose update the store" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const open_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.lish","languageId":"lish","version":1,"text":"(+ 1 2)"}}}
    ;
    try server.handle(open_msg, arena.allocator());
    {
        const doc = server.documents.get("file:///a.lish") orelse return error.MissingDoc;
        try std.testing.expectEqualStrings("(+ 1 2)", doc.text);
        try std.testing.expectEqual(@as(i64, 1), doc.version);
    }

    const change_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.lish","version":2},"contentChanges":[{"text":"(+ 3 4)"}]}}
    ;
    try server.handle(change_msg, arena.allocator());
    {
        const doc = server.documents.get("file:///a.lish") orelse return error.MissingDoc;
        try std.testing.expectEqualStrings("(+ 3 4)", doc.text);
        try std.testing.expectEqual(@as(i64, 2), doc.version);
    }

    const close_msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///a.lish"}}}
    ;
    try server.handle(close_msg, arena.allocator());
    try std.testing.expect(server.documents.get("file:///a.lish") == null);

    // didOpen and didChange both publish diagnostics; didClose does not.
    // For valid lish input we should see two publishDiagnostics notifications.
    const out = out_writer.buffered();
    var count: usize = 0;
    var search_at: usize = 0;
    while (std.mem.indexOfPos(u8, out, search_at, "publishDiagnostics")) |idx| {
        count += 1;
        search_at = idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "didChange takes last change for full sync" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.lish","languageId":"lish","version":1,"text":"initial"}}}
    , arena.allocator());

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///b.lish","version":3},"contentChanges":[{"text":"first"},{"text":"second"},{"text":"final"}]}}
    , arena.allocator());

    const doc = server.documents.get("file:///b.lish") orelse return error.MissingDoc;
    try std.testing.expectEqualStrings("final", doc.text);
}

test "didOpen on broken source emits a diagnostic" {
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///bad.lish","languageId":"lish","version":1,"text":"(+ 1 2"}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "file:///bad.lish") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"severity\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"lish\"") != null);
    // The diagnostics array should be non-empty.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"diagnostics\":[]") == null);
}

test "didOpen on valid source emits empty diagnostics" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///ok.lish","languageId":"lish","version":1,"text":"(+ 1 2)"}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"diagnostics\":[]") != null);
}

test "semanticTokens/full returns encoded data" {
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.lish","languageId":"lish","version":1,"text":"(+ 1 2)"}}}
    , arena.allocator());

    try server.handle(
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///x.lish"}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"data\":[") != null);
    // (+ 1 2) tokenizes to identifier "+" then two numbers — 3 tokens, 15 u32s.
    // We don't pin the exact array here (positions are delta-encoded), but it
    // must be non-empty.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"data\":[]") == null);
}

test "semanticTokens/full on unknown document returns null" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///missing.lish"}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "initialize advertises semanticTokensProvider" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"semanticTokensProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tokenTypes\":[\"comment\"") != null);
}

test "didChange on unknown document logs but does not crash" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [1024]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///never-opened.lish","version":2},"contentChanges":[{"text":"x"}]}}
    , arena.allocator());

    try std.testing.expectEqual(@as(usize, 0), out_writer.buffered().len);
    try std.testing.expect(std.mem.indexOf(u8, log_writer.buffered(), "DocumentNotFound") != null);
}
