//! The server's view of the lish vocabulary.
//!
//! Wraps a live `lish.Registry` populated with the builtins, the random
//! fragment, and the bundled stdlib macros: exactly the names a plain `lish`
//! host knows out of the box. Tooling (semantic tokens, hover) asks this what a
//! given identifier *is* so highlighting and docs are driven by the real
//! registry rather than a hard-coded keyword list.
//!
//! A custom host with its own DSL would build its own registry the same way and
//! hand it here; nothing below is specific to the standard vocabulary.

const std = @import("std");
const lish = @import("lish");
const snippet = @import("snippet.zig");

const Allocator = std.mem.Allocator;
const Registry = lish.Registry;
const Operation = lish.Operation;
const Macro = lish.Macro;

/// Op categories whose members read as control structure rather than function
/// calls, so editors should theme them like language keywords. Derived from the
/// registry's own category stamps, not a name list, so new ops in these groups
/// pick up keyword styling for free.
const KEYWORD_CATEGORIES = [_][]const u8{ "control", "binding", "sequencing" };

/// What an identifier in callable position resolves to. Drives the token type
/// the highlighter emits for an operator.
pub const OperatorClass = enum {
    /// A builtin in a keyword-like category (`if`, `let`, `loop`, ...).
    keyword,
    /// Any other builtin operation.
    function,
    /// A stdlib (or host) macro.
    macro,
    /// Not a known op or macro: a local binding, a user macro defined in the
    /// document, or a typo. Themed like a plain identifier.
    unknown,
};

/// A resolved vocabulary entry, for hover. Signatures for macros are rendered
/// on demand into the owning registry's arena.
pub const Symbol = struct {
    kind: enum { operation, macro },
    name: []const u8,
    signature: []const u8,
    /// One-line summary. Empty for macros, which carry no description.
    description: []const u8,
    category: ?[]const u8,
};

/// Classify an operation by its category stamp: a keyword-category member reads
/// as a keyword, everything else as a function.
fn classifyOp(op: Operation) OperatorClass {
    if (op.category) |category| {
        for (KEYWORD_CATEGORIES) |keyword_category| {
            if (std.mem.eql(u8, category, keyword_category)) return .keyword;
        }
    }
    return .function;
}

/// JSON shape of one operation in a `lish --dump-ops` array. The display
/// `signature` string in the dump is ignored (and tolerated via
/// `ignore_unknown_fields`): it is re-rendered from the structured `params`.
const VocabParam = struct {
    name: []const u8,
    role: []const u8 = "value",
    arity: []const u8 = "single",
};

const VocabOp = struct {
    name: []const u8,
    category: ?[]const u8 = null,
    description: []const u8 = "",
    returns: []const u8 = "value",
    binding_pairs: bool = false,
    params: []const VocabParam = &.{},
};

/// Registered for host vocabulary ops so their metadata is discoverable; never
/// executed (the server only reads op metadata, it never calls an op).
fn vocabularyNoop(args: lish.Args) lish.exec.ExecError!?lish.Value {
    _ = args;
    return null;
}

fn parseRole(text: []const u8) lish.Param.Role {
    if (std.mem.eql(u8, text, "binding")) return .binding;
    if (std.mem.eql(u8, text, "body")) return .body;
    return .value;
}

fn parseArity(text: []const u8) lish.Param.Arity {
    if (std.mem.eql(u8, text, "optional")) return .optional;
    if (std.mem.eql(u8, text, "variadic")) return .variadic;
    return .single;
}

pub const LishRegistry = struct {
    registry: Registry,
    allocator: Allocator,
    /// Throwaway config bound to the repl-config ops in the config-file variant
    /// (their metadata is read; they are never executed). Heap-allocated for a
    /// stable address. Null in the standard variant.
    config: ?*lish.repl.ReplConfig = null,

    /// Build a registry with the standard vocabulary (builtins + random auto-load
    /// the stdlib).
    pub fn init(allocator: Allocator) Allocator.Error!LishRegistry {
        var registry = Registry.init(allocator);
        errdefer registry.deinit(allocator);

        try lish.builtins.registerAll(&registry, allocator);
        try lish.random.registerAll(&registry, allocator);

        return .{ .registry = registry, .allocator = allocator };
    }

    /// Like `init`, plus the REPL config ops, for tooling on a lish config file.
    pub fn initWithConfigOps(allocator: Allocator) Allocator.Error!LishRegistry {
        var self = try init(allocator);
        errdefer self.deinit();

        const config = try allocator.create(lish.repl.ReplConfig);
        errdefer allocator.destroy(config);
        config.* = lish.repl.ReplConfig.init(allocator);
        errdefer config.deinit();

        try lish.repl.registerConfigOps(&self.registry, config, allocator);
        self.config = config;
        return self;
    }

    pub fn deinit(self: *LishRegistry) void {
        self.registry.deinit(self.allocator);
        if (self.config) |config| {
            config.deinit();
            self.allocator.destroy(config);
        }
    }

    pub const VocabularyError = error{InvalidVocabulary} || Allocator.Error;

    /// Merge a host vocabulary (a `lish --dump-ops` JSON array) into the registry
    /// as metadata-only operations, reconstructing each op's structured signature
    /// (params, roles, arity) so completion, hover, snippets, AND binding/scope
    /// analysis treat host ops exactly like builtins. A name already known is
    /// skipped, so a host vocabulary cannot shadow the core. Returns the count
    /// merged. Kept strings are duped into the registry arena (registry lifetime).
    pub fn loadVocabulary(self: *LishRegistry, json_bytes: []const u8) VocabularyError!usize {
        const parsed = std.json.parseFromSlice(
            []VocabOp,
            self.allocator,
            json_bytes,
            .{ .ignore_unknown_fields = true },
        ) catch return error.InvalidVocabulary;
        defer parsed.deinit();

        const arena = self.registry.macroAllocator();
        var count: usize = 0;
        for (parsed.value) |source_op| {
            if (source_op.name.len == 0) continue;
            if (self.registry.getOperation(source_op.name) != null) continue;
            if (self.registry.getMacro(source_op.name) != null) continue;

            const params = try arena.alloc(lish.Param, source_op.params.len);
            for (source_op.params, 0..) |source_param, i| params[i] = .{
                .name = try arena.dupe(u8, source_param.name),
                .role = parseRole(source_param.role),
                .arity = parseArity(source_param.arity),
            };

            var op = lish.Operation.fromFn(vocabularyNoop, .{
                .signature = .{
                    .params = params,
                    .returns = try arena.dupe(u8, source_op.returns),
                    .binding_pairs = source_op.binding_pairs,
                },
                .description = try arena.dupe(u8, source_op.description),
            });
            if (source_op.category) |category| op.category = try arena.dupe(u8, category);

            try self.registry.registerOperation(self.allocator, try arena.dupe(u8, source_op.name), op);
            count += 1;
        }
        return count;
    }

    /// Classify a name appearing in callable (operator) position.
    pub fn classifyOperator(self: *const LishRegistry, name: []const u8) OperatorClass {
        if (self.registry.getOperation(name)) |op| return classifyOp(op);
        if (self.registry.getMacro(name) != null) return .macro;
        return .unknown;
    }

    /// A completion candidate drawn from the vocabulary. `class` is never
    /// `.unknown` (only registered names are enumerated).
    pub const Candidate = struct {
        name: []const u8,
        class: OperatorClass,
        /// Call signature, e.g. `clamp lo hi x`.
        detail: []const u8,
        /// One-line summary; empty for macros (which carry none).
        documentation: []const u8,
        /// LSP snippet body, e.g. `clamp ${1:lo} ${2:hi} ${3:x}`.
        snippet: []const u8,
    };

    /// Render an operation's structured signature to its display string,
    /// allocated in the registry's macro arena (lives as long as the registry).
    fn renderSignature(self: *LishRegistry, op: Operation, name: []const u8) Allocator.Error![]const u8 {
        var signature: std.Io.Writer.Allocating = .init(self.registry.macroAllocator());
        op.signature.render(&signature.writer, name) catch return error.OutOfMemory;
        return signature.written();
    }

    /// Build an op's completion snippet: a placeholder per non-optional
    /// parameter (optionals are left for the user to add).
    fn opSnippet(self: *LishRegistry, op: Operation, name: []const u8) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.registry.macroAllocator());
        out.writer.writeAll(name) catch return error.OutOfMemory;
        var n: usize = 1;
        for (op.signature.params) |param| {
            if (param.arity == .optional) continue;
            snippet.writePlaceholder(&out.writer, n, param.name) catch return error.OutOfMemory;
            n += 1;
        }
        return out.written();
    }

    /// Build a macro's completion snippet: a placeholder per parameter.
    fn macroSnippet(self: *LishRegistry, macro: *const Macro, name: []const u8) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.registry.macroAllocator());
        out.writer.writeAll(name) catch return error.OutOfMemory;
        for (macro.parameters, 1..) |param, n| {
            snippet.writePlaceholder(&out.writer, n, param.id) catch return error.OutOfMemory;
        }
        return out.written();
    }

    /// Append every operation and macro whose name starts with `prefix` to
    /// `out`. Macro signatures are rendered into the registry's macro arena
    /// (live as long as the registry); `out`'s storage uses `allocator`.
    pub fn collectMatching(
        self: *LishRegistry,
        prefix: []const u8,
        out: *std.ArrayListUnmanaged(Candidate),
        allocator: Allocator,
    ) Allocator.Error!void {
        var op_it = self.registry.operations.iterator();
        while (op_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const op = entry.value_ptr.*;
            try out.append(allocator, .{
                .name = name,
                .class = classifyOp(op),
                .detail = try self.renderSignature(op, name),
                .documentation = op.description,
                .snippet = try self.opSnippet(op, name),
            });
        }

        var macro_it = self.registry.macros.iterator();
        while (macro_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const macro = entry.value_ptr.*;
            var signature: std.Io.Writer.Allocating = .init(self.registry.macroAllocator());
            macro.writeSignature(&signature.writer) catch return error.OutOfMemory;
            try out.append(allocator, .{
                .name = name,
                .class = .macro,
                .detail = signature.written(),
                .documentation = "",
                .snippet = try self.macroSnippet(macro, name),
            });
        }
    }

    /// Resolve a name to its documentation entry, or null if unknown. A rendered
    /// macro signature is allocated into the registry's macro arena (lives as
    /// long as the registry).
    pub fn lookup(self: *LishRegistry, name: []const u8) Allocator.Error!?Symbol {
        if (self.registry.getOperation(name)) |op| {
            return .{
                .kind = .operation,
                .name = name,
                .signature = try self.renderSignature(op, name),
                .description = op.description,
                .category = op.category,
            };
        }
        if (self.registry.getMacro(name)) |macro| {
            var signature: std.Io.Writer.Allocating = .init(self.registry.macroAllocator());
            // The only way writing into an allocating buffer fails is OOM.
            macro.writeSignature(&signature.writer) catch return error.OutOfMemory;
            return .{
                .kind = .macro,
                .name = name,
                .signature = signature.written(),
                .description = "",
                .category = null,
            };
        }
        return null;
    }
};

test "classifyOperator distinguishes keyword, function, macro, unknown" {
    var lr = try LishRegistry.init(std.testing.allocator);
    defer lr.deinit();

    try std.testing.expectEqual(OperatorClass.keyword, lr.classifyOperator("if"));
    try std.testing.expectEqual(OperatorClass.keyword, lr.classifyOperator("let"));
    try std.testing.expectEqual(OperatorClass.function, lr.classifyOperator("+"));
    try std.testing.expectEqual(OperatorClass.unknown, lr.classifyOperator("definitely-not-an-op"));
}

test "lookup returns operation signature and description" {
    var lr = try LishRegistry.init(std.testing.allocator);
    defer lr.deinit();

    const sym = (try lr.lookup("+")) orelse return error.MissingSymbol;
    try std.testing.expectEqual(@as(@TypeOf(sym.kind), .operation), sym.kind);
    try std.testing.expect(sym.signature.len > 0);
    try std.testing.expect(sym.description.len > 0);
}

test "lookup of unknown name returns null" {
    var lr = try LishRegistry.init(std.testing.allocator);
    defer lr.deinit();

    try std.testing.expect((try lr.lookup("definitely-not-an-op")) == null);
}

test "collectMatching returns prefix-matching ops and macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lr = try LishRegistry.init(a);
    defer lr.deinit();

    var out: std.ArrayListUnmanaged(LishRegistry.Candidate) = .empty;
    try lr.collectMatching("cl", &out, a);

    // "clamp" / "clamp01" are stdlib macros; everything returned starts with "cl".
    try std.testing.expect(out.items.len > 0);
    var saw_clamp = false;
    for (out.items) |candidate| {
        try std.testing.expect(std.mem.startsWith(u8, candidate.name, "cl"));
        if (std.mem.eql(u8, candidate.name, "clamp")) saw_clamp = true;
    }
    try std.testing.expect(saw_clamp);
}

test "loadVocabulary merges host ops with structured param roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lr = try LishRegistry.init(a);
    defer lr.deinit();

    const json =
        \\[
        \\  { "name": "each", "category": "host", "description": "Iterate.",
        \\    "signature": "each item list body -> $none", "returns": "$none",
        \\    "params": [
        \\      { "name": "item", "role": "binding", "arity": "single" },
        \\      { "name": "list", "role": "value", "arity": "single" },
        \\      { "name": "body", "role": "body", "arity": "single" }
        \\    ] }
        \\]
    ;
    const merged = try lr.loadVocabulary(json);
    try std.testing.expectEqual(@as(usize, 1), merged);

    // Visible as a known operator (so semantic tokens stop flagging it unknown).
    try std.testing.expectEqual(OperatorClass.function, lr.classifyOperator("each"));

    // Hover re-renders the signature from the structured params + description.
    const sym = (try lr.lookup("each")) orelse return error.MissingSymbol;
    try std.testing.expectEqualStrings("each item list body -> $none", sym.signature);
    try std.testing.expectEqualStrings("Iterate.", sym.description);

    // The fidelity point: param roles survive, so scope/binding analysis works.
    const op = lr.registry.getOperation("each").?;
    try std.testing.expectEqual(lish.Param.Role.binding, op.signature.params[0].role);
    try std.testing.expectEqual(lish.Param.Role.value, op.signature.params[1].role);
    try std.testing.expectEqual(lish.Param.Role.body, op.signature.params[2].role);
}

test "loadVocabulary does not shadow a builtin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lr = try LishRegistry.init(a);
    defer lr.deinit();

    const merged = try lr.loadVocabulary(
        \\[ { "name": "map", "description": "evil override", "returns": "x", "params": [] } ]
    );
    try std.testing.expectEqual(@as(usize, 0), merged);
    const sym = (try lr.lookup("map")).?;
    try std.testing.expect(!std.mem.eql(u8, sym.description, "evil override"));
}

test "loadVocabulary rejects malformed JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lr = try LishRegistry.init(a);
    defer lr.deinit();

    try std.testing.expectError(error.InvalidVocabulary, lr.loadVocabulary("not json"));
}

test "collectMatching classifies a keyword-category op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lr = try LishRegistry.init(a);
    defer lr.deinit();

    var out: std.ArrayListUnmanaged(LishRegistry.Candidate) = .empty;
    try lr.collectMatching("if", &out, a);

    var found_if = false;
    for (out.items) |candidate| {
        if (std.mem.eql(u8, candidate.name, "if")) {
            try std.testing.expectEqual(OperatorClass.keyword, candidate.class);
            found_if = true;
        }
    }
    try std.testing.expect(found_if);
}
