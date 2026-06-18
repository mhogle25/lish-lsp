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

pub const LishRegistry = struct {
    registry: Registry,
    allocator: Allocator,

    /// Build a registry with the standard vocabulary: builtins + random + stdlib.
    pub fn init(allocator: Allocator) Allocator.Error!LishRegistry {
        var registry = Registry.init(allocator);
        errdefer registry.deinit(allocator);

        try lish.builtins.registerAll(&registry, allocator);
        try lish.random.registerAll(&registry, allocator);
        _ = try lish.loadStdlib(&registry);

        return .{ .registry = registry, .allocator = allocator };
    }

    pub fn deinit(self: *LishRegistry) void {
        self.registry.deinit(self.allocator);
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
    };

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
                .detail = op.signature,
                .documentation = op.description,
            });
        }

        var macro_it = self.registry.macros.iterator();
        while (macro_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            var signature: std.Io.Writer.Allocating = .init(self.registry.macroAllocator());
            entry.value_ptr.*.writeSignature(&signature.writer) catch return error.OutOfMemory;
            try out.append(allocator, .{
                .name = name,
                .class = .macro,
                .detail = signature.written(),
                .documentation = "",
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
                .signature = op.signature,
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
