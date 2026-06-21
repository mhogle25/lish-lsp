//! LSP server state machine + method dispatch.
//!
//! Tracks the protocol lifecycle (uninitialized -> initialized -> shutdown -> exit),
//! gates which methods may run in each state, and emits JSON-RPC responses through
//! the supplied writer.

const std = @import("std");
const lish = @import("lish");

// The analysis engines + plumbing come from the reusable library module
// (src/root.zig), so the library compiles once and folio-lsp shares the exact
// same code + types. server.zig and main.zig are the only binary-private files.
const lish_lsp = @import("lish_lsp");
const protocol = lish_lsp.protocol;
const document_store = lish_lsp.document_store;
const diagnostics_mod = lish_lsp.diagnostics;
const semantic_tokens = lish_lsp.semantic_tokens;
const hover_mod = lish_lsp.hover;
const completion_mod = lish_lsp.completion;
const signature_help_mod = lish_lsp.signature_help;
const lish_registry = lish_lsp.lish_registry;
const definition_mod = lish_lsp.definition;
const workspace_index = lish_lsp.workspace_index;
const uri_mod = lish_lsp.uri;
const core = lish_lsp.server_core;
const feature_encode = lish_lsp.feature_encode;

pub const DocumentStore = document_store.DocumentStore;
pub const Document = document_store.Document;
pub const LishRegistry = lish_registry.LishRegistry;
pub const WorkspaceIndex = workspace_index.WorkspaceIndex;

// Lifecycle, error codes, and generic JSON helpers live in server_core (shared
// with folio-lsp); re-exported / aliased here so existing references are unchanged.
pub const State = core.State;
pub const ErrorCode = core.ErrorCode;
const stringField = core.stringField;
const writeJsonString = core.writeJsonString;

pub const Server = struct {
    state: State = .uninitialized,
    /// Set true when the server should exit cleanly (received `exit` after `shutdown`).
    should_exit: bool = false,
    /// Set true when exit was received without a prior shutdown; caller should
    /// terminate with a nonzero status per LSP spec.
    exit_was_unclean: bool = false,
    writer: *std.Io.Writer,
    log: *std.Io.Writer,
    documents: DocumentStore,
    allocator: std.mem.Allocator,
    /// Filesystem io, used by the workspace index to scan `.lishmacro` files on
    /// disk. Set by `main` after construction; left `undefined` in tests that
    /// never trigger a disk scan (no workspace roots).
    io: std.Io = undefined,
    /// The standard lish vocabulary, built lazily on first feature use (semantic
    /// tokens or hover) so the lifecycle tests that never request them pay
    /// nothing. Owned here; torn down in `deinit`.
    registry: ?LishRegistry = null,
    /// Like `registry` but with the REPL config ops included, used for lish
    /// config-file documents. Lazy.
    config_registry: ?LishRegistry = null,
    /// Workspace macro index for go-to-definition, built lazily on the first
    /// definition request and rebuilt when a `.lishmacro` document changes.
    index: ?WorkspaceIndex = null,
    /// True when the index must be (re)built before the next lookup.
    index_dirty: bool = true,
    /// Workspace root paths from `initialize` (`workspaceFolders`/`rootUri`/
    /// `rootPath`). Each path and the backing list are owned by `allocator`.
    roots: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Host-vocabulary file specs from `initialize`
    /// (`initializationOptions.vocabulary`): each a path to a `lish --dump-ops`
    /// JSON file, absolute or relative to the first workspace root. Merged into
    /// the standard registry on first use. Each string and the list are owned by
    /// `allocator`.
    vocabulary_specs: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, log: *std.Io.Writer) Server {
        return .{
            .writer = writer,
            .log = log,
            .documents = DocumentStore.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(server: *Server) void {
        server.documents.deinit();
        if (server.registry) |*registry| registry.deinit();
        if (server.config_registry) |*registry| registry.deinit();
        if (server.index) |*index| index.deinit();
        for (server.roots.items) |root| server.allocator.free(root);
        server.roots.deinit(server.allocator);
        for (server.vocabulary_specs.items) |spec| server.allocator.free(spec);
        server.vocabulary_specs.deinit(server.allocator);
    }

    /// Build the vocabulary registry on first use and return it thereafter. Host
    /// vocabulary files (`initializationOptions.vocabulary`) are merged in right
    /// after the standard vocabulary, so host ops behave like builtins.
    fn ensureRegistry(server: *Server) std.mem.Allocator.Error!*LishRegistry {
        if (server.registry == null) {
            server.registry = try LishRegistry.init(server.allocator);
            server.loadVocabularies(&server.registry.?);
        }
        return &server.registry.?;
    }

    /// Merge host vocabulary into `registry` (explicit specs + per-project
    /// `lish.ops.json`). Generic loading lives in `server_core`.
    fn loadVocabularies(server: *Server, registry: *LishRegistry) void {
        _ = core.loadVocabularies(
            "lish-lsp",
            core.PROJECT_VOCABULARY_FILE,
            server.io,
            server.log,
            server.allocator,
            registry,
            server.vocabulary_specs.items,
            server.roots.items,
        );
    }

    /// The registry appropriate to `uri`: the config-ops-included one for a lish
    /// config file, the standard one otherwise. Both are built lazily.
    fn registryFor(server: *Server, uri: []const u8) std.mem.Allocator.Error!*LishRegistry {
        if (!isConfigFile(uri)) return server.ensureRegistry();
        if (server.config_registry == null) server.config_registry = try LishRegistry.initWithConfigOps(server.allocator);
        return &server.config_registry.?;
    }

    /// Build the workspace macro index on first use, rebuilding it when a
    /// `.lishmacro` document has changed since the last lookup. Open documents
    /// win over their on-disk copies (see `WorkspaceIndex.build`).
    fn ensureIndex(server: *Server) std.mem.Allocator.Error!*WorkspaceIndex {
        if (server.index == null) server.index = WorkspaceIndex.init(server.allocator);
        const index = &server.index.?;
        if (server.index_dirty) {
            try index.build(server.io, server.allocator, server.roots.items, &server.documents);
            server.index_dirty = false;
        }
        return index;
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
        if (core.lifecycleReject(server.state, method)) |rej| {
            if (id) |req_id| try server.sendError(req_id, rej.code, rej.message);
            return;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            const req_id = id orelse return; // initialize must be a request
            try server.handleInitialize(req_id, params);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // Notification: no response. State already moved on the initialize response.
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
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            const req_id = id orelse return;
            try server.handleHover(req_id, params);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            const req_id = id orelse return;
            try server.handleDefinition(req_id, params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            const req_id = id orelse return;
            try server.handleCompletion(req_id, params);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            const req_id = id orelse return;
            try server.handleSignatureHelp(req_id, params);
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
        server.markIndexDirtyIfMacro(uri);
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

        // We advertised full sync (kind 1): take the last change's `text`.
        const last = changes[changes.len - 1];
        if (last != .object) return;
        const text_val = last.object.get("text") orelse return;
        if (text_val != .string) return;

        try server.documents.replace(uri, text_val.string, version);
        server.markIndexDirtyIfMacro(uri);
        try server.publishDiagnostics(uri);
    }

    /// Parse the document and emit a publishDiagnostics notification.
    /// Always emits, even an empty diagnostic list, so the editor clears
    /// stale errors from a previous parse.
    fn publishDiagnostics(server: *Server, uri: []const u8) !void {
        const doc = server.documents.get(uri) orelse return;

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var diags: std.ArrayList(diagnostics_mod.Diagnostic) = .empty;
        switch (languageOf(uri)) {
            .expression => {
                const root = try lish.parser.parse(a, doc.text);
                try diagnostics_mod.collect(root, &diags, a);
            },
            .macro => {
                const module = try lish.macro_parser.parseMacroModule(a, doc.text);
                try diagnostics_mod.collectMacro(module, &diags, a);
            },
        }

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);

        // Build the notification body. We do this in a growable buffer because
        // diagnostic count + message length are unbounded.
        var body: std.Io.Writer.Allocating = .init(a);
        const bw = &body.writer;

        try bw.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try writeJsonString(bw, uri);
        try bw.print("\",\"version\":{d},\"diagnostics\":", .{doc.version});
        try feature_encode.diagnostics(bw, diags.items, line_table, "lish");
        try bw.writeAll("}}");

        try protocol.writeMessage(server.writer, body.written());
    }

    fn handleDidClose(server: *Server, params: ?std.json.Value) void {
        const td = textDocumentOf(params) orelse return;
        const uri = stringField(td, "uri") orelse return;
        server.documents.close(uri);
        server.markIndexDirtyIfMacro(uri);
    }

    /// A `.lishmacro` document opening, changing, or closing can alter the set of
    /// known macros, so the index must rebuild before the next lookup.
    fn markIndexDirtyIfMacro(server: *Server, uri: []const u8) void {
        if (languageOf(uri) == .macro) server.index_dirty = true;
    }

    fn handleInitialize(server: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        server.state = .initialized;
        server.collectRoots(params) catch |err| {
            server.log.print("lish-lsp: collectRoots failed: {s}\n", .{@errorName(err)}) catch {};
            server.log.flush() catch {};
        };
        server.collectVocabularySpecs(params) catch |err| {
            server.log.print("lish-lsp: collectVocabularySpecs failed: {s}\n", .{@errorName(err)}) catch {};
            server.log.flush() catch {};
        };

        var buf: [2048]u8 = undefined;
        var bw = std.Io.Writer.fixed(&buf);
        try bw.writeAll("{\"capabilities\":{\"textDocumentSync\":1,\"positionEncoding\":\"utf-16\",\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[");
        inline for (semantic_tokens.TOKEN_TYPES, 0..) |name, i| {
            if (i != 0) try bw.writeByte(',');
            try bw.print("\"{s}\"", .{name});
        }
        // No `triggerCharacters`: in a lisp every call opens with `(`, so making
        // `(` a trigger would dump the whole vocabulary on every paren and (with
        // editor autopairs inserting the closing `)`) leaves completion relying
        // on a stale filtered set that gets cleared. Letting completion fire on
        // the operator name's first letter (the client's keyword trigger) is both
        // less noisy and works identically at any nesting depth.
        try bw.writeAll("],\"tokenModifiers\":[]},\"full\":true},\"hoverProvider\":true,\"definitionProvider\":true,\"completionProvider\":{},\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\" \"],\"retriggerCharacters\":[\" \"]}},\"serverInfo\":{\"name\":\"lish-lsp\",\"version\":\"0.0.0\"}}");
        try server.sendResult(id, bw.buffered());
    }

    /// Record the workspace roots from `initialize` params (generic; lives in
    /// `server_core`).
    fn collectRoots(server: *Server, params: ?std.json.Value) !void {
        return core.collectRoots(server.allocator, &server.roots, params);
    }

    /// Record `initializationOptions.vocabulary` (a string or array of strings)
    /// as host-vocabulary file specs. Anything else is ignored.
    fn collectVocabularySpecs(server: *Server, params: ?std.json.Value) !void {
        return core.collectVocabularySpecs(server.allocator, &server.vocabulary_specs, params);
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

        const registry = try server.registryFor(uri);
        const index = try server.ensureIndex();
        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);
        const data = try semantic_tokens.encode(doc.text, line_table, registry, index, languageOf(uri), a);

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

    fn handleHover(server: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const td = textDocumentOf(params) orelse return server.sendResult(id, "null");
        const uri = stringField(td, "uri") orelse return server.sendResult(id, "null");
        const doc = server.documents.get(uri) orelse return server.sendResult(id, "null");
        const position = core.positionOf(params) orelse return server.sendResult(id, "null");

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);
        const cursor = line_table.byteAt(position.line, position.character);
        if (cursor >= doc.text.len) return server.sendResult(id, "null");

        const registry = try server.registryFor(uri);
        const index = try server.ensureIndex();
        const result = (switch (languageOf(uri)) {
            .expression => try hover_mod.hoverAt(doc.text, cursor, registry, index, a),
            .macro => try hover_mod.hoverAtMacro(doc.text, cursor, registry, index, a),
        }) orelse return server.sendResult(id, "null");

        var body: std.Io.Writer.Allocating = .init(a);
        try feature_encode.hover(&body.writer, result.markdown, line_table.position(result.start), line_table.position(result.end));
        try server.sendResult(id, body.written());
    }

    fn handleDefinition(server: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const td = textDocumentOf(params) orelse return server.sendResult(id, "null");
        const uri = stringField(td, "uri") orelse return server.sendResult(id, "null");
        const doc = server.documents.get(uri) orelse return server.sendResult(id, "null");
        const position = core.positionOf(params) orelse return server.sendResult(id, "null");

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);
        const cursor = line_table.byteAt(position.line, position.character);
        if (cursor >= doc.text.len) return server.sendResult(id, "null");

        const index = try server.ensureIndex();
        const location = (switch (languageOf(uri)) {
            .expression => try definition_mod.defineExpression(doc.text, cursor, index, a),
            .macro => try definition_mod.defineMacro(doc.text, cursor, uri, index, a),
        }) orelse return server.sendResult(id, "null");

        // The location's byte span is relative to its own document, which may be
        // a different file. Convert it with that document's line structure.
        const target_text = (try server.targetText(location.uri, a)) orelse return server.sendResult(id, "null");
        const target_table = try diagnostics_mod.LineTable.build(target_text, a);
        const start = target_table.position(location.start);
        const end = target_table.position(location.end);

        var body: std.Io.Writer.Allocating = .init(a);
        const bw = &body.writer;
        try bw.writeAll("{\"uri\":\"");
        try writeJsonString(bw, location.uri);
        try bw.print(
            "\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}",
            .{ start.line, start.character, end.line, end.character },
        );
        try server.sendResult(id, body.written());
    }

    /// The text of the document a definition lives in: the open buffer if we have
    /// one (so unsaved edits resolve correctly), otherwise the file read from
    /// disk. Returns null if the URI is unreadable.
    fn targetText(server: *Server, target_uri: []const u8, arena: std.mem.Allocator) !?[]const u8 {
        if (server.documents.get(target_uri)) |doc| return doc.text;
        const path = (try uri_mod.toPath(arena, target_uri)) orelse return null;
        return std.Io.Dir.cwd().readFileAlloc(server.io, path, arena, .limited(lish.MACRO_FILE_MAX_SIZE)) catch null;
    }

    fn handleCompletion(server: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const td = textDocumentOf(params) orelse return server.sendResult(id, "[]");
        const uri = stringField(td, "uri") orelse return server.sendResult(id, "[]");
        const doc = server.documents.get(uri) orelse return server.sendResult(id, "[]");
        const position = core.positionOf(params) orelse return server.sendResult(id, "[]");

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);
        const cursor = line_table.byteAt(position.line, position.character);
        if (cursor > doc.text.len) return server.sendResult(id, "[]");

        const registry = try server.registryFor(uri);
        const index = try server.ensureIndex();
        const result = (try completion_mod.collect(doc.text, cursor, registry, index, languageOf(uri), a)) orelse
            return server.sendResult(id, "[]");

        // The replaced word runs from where it begins to the cursor; the same
        // edit range applies to every item.
        var body: std.Io.Writer.Allocating = .init(a);
        try feature_encode.completionList(&body.writer, result.items, line_table.position(result.replace_start), line_table.position(cursor));
        try server.sendResult(id, body.written());
    }

    fn handleSignatureHelp(server: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const td = textDocumentOf(params) orelse return server.sendResult(id, "null");
        const uri = stringField(td, "uri") orelse return server.sendResult(id, "null");
        const doc = server.documents.get(uri) orelse return server.sendResult(id, "null");
        const position = core.positionOf(params) orelse return server.sendResult(id, "null");

        var arena = std.heap.ArenaAllocator.init(server.documents.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const line_table = try diagnostics_mod.LineTable.build(doc.text, a);
        const cursor = line_table.byteAt(position.line, position.character);
        if (cursor > doc.text.len) return server.sendResult(id, "null");

        const registry = try server.registryFor(uri);
        const help = (try signature_help_mod.at(doc.text, cursor, registry, languageOf(uri), a)) orelse
            return server.sendResult(id, "null");

        var body: std.Io.Writer.Allocating = .init(a);
        try feature_encode.signatureHelp(&body.writer, help);
        try server.sendResult(id, body.written());
    }

    /// Emit a success response: `{"jsonrpc":"2.0","id":<id>,"result":<result_json>}`.
    /// `result_json` is a raw JSON fragment (e.g. `"null"` or an object literal).
    fn sendResult(server: *Server, id: std.json.Value, result_json: []const u8) !void {
        return core.sendResult(server.writer, id, result_json);
    }

    fn sendError(server: *Server, id: std.json.Value, code: ErrorCode, message: []const u8) !void {
        return core.sendError(server.writer, id, code, message);
    }
};

fn textDocumentOf(params: ?std.json.Value) ?std.json.ObjectMap {
    const p = params orelse return null;
    if (p != .object) return null;
    const td = p.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    return td.object;
}

/// Pick the grammar a document follows from its URI: `.lishmacro` files are
/// macro modules, everything else (notably `.lish`) is an expression document.
fn languageOf(uri: []const u8) semantic_tokens.Language {
    return if (std.mem.endsWith(u8, uri, lish.MACRO_EXTENSION)) .macro else .expression;
}

/// Whether `uri` is a lish REPL config file (`.../lish/config.lish`), where the
/// repl-config ops are in scope.
fn isConfigFile(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, "/lish/config.lish");
}

fn versionField(obj: std.json.ObjectMap) i64 {
    const v = obj.get("version") orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
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
    // (+ 1 2) tokenizes to identifier "+" then two numbers: 3 tokens, 15 u32s.
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

test "initialize advertises definitionProvider" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "\"definitionProvider\":true") != null);
}

test "initialize records a rootUri as a workspace root" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///home/proj"}}
    , arena.allocator());

    try std.testing.expectEqual(@as(usize, 1), server.roots.items.len);
    try std.testing.expectEqualStrings("/home/proj", server.roots.items[0]);
}

test "host vocabulary from initializationOptions is merged into the registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var io_instance: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    // A host vocabulary file: one op carrying a binding param, so we also prove
    // the structured roles survive the JSON round-trip end to end.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "vocab.json", .data =
        \\[ { "name": "eachthing", "category": "host", "description": "Host iter.",
        \\    "returns": "$none",
        \\    "params": [ { "name": "x", "role": "binding", "arity": "single" },
        \\                { "name": "xs", "role": "value", "arity": "single" },
        \\                { "name": "body", "role": "body", "arity": "single" } ] } ]
    });

    // Root is the tmp dir (relative to cwd); the vocabulary path is relative to
    // that root, so resolveVocabularyPath joins them and the read works without
    // any absolute-path machinery.
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [512]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    server.io = io;
    defer server.deinit();

    const msg = try std.mem.concat(a, u8, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootPath\":\"",
        root,
        "\",\"initializationOptions\":{\"vocabulary\":[\"vocab.json\"]}}}",
    });
    try server.handle(msg, a);
    try std.testing.expectEqual(@as(usize, 1), server.vocabulary_specs.items.len);

    // ensureRegistry reads the file (via io) and merges the host op, which then
    // behaves exactly like a builtin: classified, hoverable, with its binding
    // role intact for scope-aware completion.
    const registry = try server.ensureRegistry();
    try std.testing.expectEqual(lish_registry.OperatorClass.function, registry.classifyOperator("eachthing"));
    const sym = (try registry.lookup("eachthing")).?;
    try std.testing.expectEqualStrings("eachthing x xs body -> $none", sym.signature);
    const op = registry.registry.getOperation("eachthing").?;
    try std.testing.expectEqual(lish.Param.Role.binding, op.signature.params[0].role);
}

test "per-project lish.ops.json is auto-discovered from the workspace root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var io_instance: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    // Drop the conventionally-named file at the project root; no editor setting.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lish.ops.json", .data =
        \\[ { "name": "projop", "category": "host", "description": "A project op.",
        \\    "returns": "$none", "params": [] } ]
    });
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [1024]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    server.io = io;
    defer server.deinit();

    // initialize with only a root (no `vocabulary` option) -> the server finds
    // lish.ops.json on its own.
    const msg = try std.mem.concat(a, u8, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"rootPath\":\"",
        root,
        "\"}}",
    });
    try server.handle(msg, a);

    const registry = try server.ensureRegistry();
    try std.testing.expectEqual(lish_registry.OperatorClass.function, registry.classifyOperator("projop"));
}

test "definition jumps a macro call to its cross-file definition" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A macro library and an expression document that calls into it, both open.
    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///lib.lishmacro","languageId":"lish","version":1,"text":"| double x | * :x 2"}}}
    , arena.allocator());
    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///main.lish","languageId":"lish","version":1,"text":"(double 5)"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf); // drop the diagnostics noise

    // Cursor on "double" (line 0, char 1) in main.lish.
    try server.handle(
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///main.lish"},"position":{"line":0,"character":1}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "file:///lib.lishmacro") != null);
    // "double" header id spans bytes [2,8) on line 0.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0,\"character\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"end\":{\"line\":0,\"character\":8}") != null);
}

test "definition jumps a scope ref to its head parameter in the same document" {
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
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///m.lishmacro","languageId":"lish","version":1,"text":"| double x | * :x 2"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    // Cursor on the "x" of ":x" (line 0, char 16).
    try server.handle(
        \\{"jsonrpc":"2.0","id":10,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///m.lishmacro"},"position":{"line":0,"character":16}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "file:///m.lishmacro") != null);
    // The head parameter "x" spans bytes [9,10) on line 0.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0,\"character\":9}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"end\":{\"line\":0,\"character\":10}") != null);
}

test "definition on a builtin returns null" {
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
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///b.lish","languageId":"lish","version":1,"text":"(+ 1 2)"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    try server.handle(
        \\{"jsonrpc":"2.0","id":11,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///b.lish"},"position":{"line":0,"character":1}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "definition on an unknown document returns null" {
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
        \\{"jsonrpc":"2.0","id":12,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///missing.lish"},"position":{"line":0,"character":0}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"result\":null") != null);
}

test "initialize advertises completionProvider" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "\"completionProvider\"") != null);
}

test "completion returns prefix-matching vocabulary items with an edit range" {
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///c.lish","languageId":"lish","version":1,"text":"(ma"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    // Cursor after "(ma" (line 0, char 3).
    try server.handle(
        \\{"jsonrpc":"2.0","id":15,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///c.lish"},"position":{"line":0,"character":3}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"map\"") != null);
    // The edit replaces from the start of "ma" (char 1) to the cursor (char 3).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0,\"character\":1}") != null);
    // newText is the snippet (placeholders for the parameters), inserted as a snippet.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"insertTextFormat\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"newText\":\"map ${1:name} ${2:list} ${3:body}\"") != null);
}

test "completion after a colon offers in-scope bindings" {
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "(let total 0 (+ :t)": completing ":t" inside the body offers `total`.
    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///s.lish","languageId":"lish","version":1,"text":"(let total 0 (+ :t)"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    // Cursor right after ":t" (line 0, char 18).
    try server.handle(
        \\{"jsonrpc":"2.0","id":17,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///s.lish"},"position":{"line":0,"character":18}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"total\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":6") != null); // Variable
}

test "completion in a config file offers the repl-config ops" {
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///home/u/.config/lish/config.lish","languageId":"lish","version":1,"text":"(indent"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    try server.handle(
        \\{"jsonrpc":"2.0","id":18,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///home/u/.config/lish/config.lish"},"position":{"line":0,"character":7}}}
    , arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "\"label\":\"indent-width\"") != null);
}

test "completion in a normal file does not offer repl-config ops" {
    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///proj/script.lish","languageId":"lish","version":1,"text":"(indent"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    try server.handle(
        \\{"jsonrpc":"2.0","id":19,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///proj/script.lish"},"position":{"line":0,"character":7}}}
    , arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "indent-width") == null);
}

test "signatureHelp reports the active parameter" {
    var out_buf: [16 * 1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "(clamp 0 10 ": `clamp v lo hi`, cursor in the third arg slot.
    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///h.lish","languageId":"lish","version":1,"text":"(clamp 0 10 "}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    try server.handle(
        \\{"jsonrpc":"2.0","id":21,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///h.lish"},"position":{"line":0,"character":12}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":21") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"clamp v lo hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"activeParameter\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"hi\"") != null);
}

test "initialize advertises signatureHelpProvider" {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out_writer.buffered(), "\"signatureHelpProvider\"") != null);
}

test "completion inside a comment returns an empty list" {
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
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///d.lish","languageId":"lish","version":1,"text":"# ma"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    try server.handle(
        \\{"jsonrpc":"2.0","id":16,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///d.lish"},"position":{"line":0,"character":4}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"result\":[]") != null);
}

test "hover falls back to the workspace index for a user macro" {
    var out_buf: [8192]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out_buf);
    var log_buf: [256]u8 = undefined;
    var log_writer = std.Io.Writer.fixed(&log_buf);
    var server = Server.init(std.testing.allocator, &out_writer, &log_writer);
    defer server.deinit();
    server.state = .initialized;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///combat.lishmacro","languageId":"lish","version":1,"text":"| strike target | :target"}}}
    , arena.allocator());
    try server.handle(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///main.lish","languageId":"lish","version":1,"text":"(strike foe)"}}}
    , arena.allocator());

    out_writer = std.Io.Writer.fixed(&out_buf);

    // Cursor on "strike" (line 0, char 1) in main.lish.
    try server.handle(
        \\{"jsonrpc":"2.0","id":20,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///main.lish"},"position":{"line":0,"character":1}}}
    , arena.allocator());

    const out = out_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"id\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "strike target") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "defined in") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "combat") != null);
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
