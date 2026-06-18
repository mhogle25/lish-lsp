//! Position-indexed AST traversal shared by the LSP features.
//!
//! `collect` flattens a parse tree into source-ordered, role-tagged byte spans
//! that the semantic-tokens layer turns into LSP tokens. `nodeAt` finds the
//! deepest node covering a byte offset, which hover uses to identify what the
//! cursor is on.
//!
//! Roles are *structural*: they say where a node sits in the tree (callable
//! position, argument, scope reference, ...), not what it resolves to. Mapping a
//! role to a concrete token type, including asking the registry whether an
//! operator is a keyword or a function, is the consumer's job. That keeps this
//! walker independent of any particular vocabulary.
//!
//! Comments live outside the AST (the lexer discards them), so they are not
//! produced here; callers fold in the spans from `parser.parseWithComments`.

const std = @import("std");
const lish = @import("lish");

const Allocator = std.mem.Allocator;
const ast = lish.ast;
const AstNode = ast.AstNode;

pub const Role = enum {
    /// Identifier in callable position (the id of an expression).
    operator,
    /// Quoted string literal.
    string,
    /// Numeric literal.
    number,
    /// Bare identifier used as a value (an argument, not a call).
    identifier,
    /// Identifier behind a `:` scope thunk.
    scope_ref,
    /// A leading `$` or `:` sigil. Brackets are intentionally omitted (clients
    /// theme those themselves).
    sigil,
    /// The name a definition introduces (a macro head's identifier). Emitted by
    /// `macro_walk`, not the expression walker.
    definition,
    /// A bound parameter name (a macro head's parameter). Emitted by
    /// `macro_walk`.
    parameter,
};

pub const RoleSpan = struct {
    role: Role,
    start: u32,
    end: u32,
};

/// Walk `root` and return its role-tagged spans, sorted by start offset.
pub fn collect(root: *const AstNode, allocator: Allocator) Allocator.Error![]RoleSpan {
    var spans: std.ArrayList(RoleSpan) = .empty;
    errdefer spans.deinit(allocator);

    try appendInto(root, &spans, allocator);

    const items = try spans.toOwnedSlice(allocator);
    std.mem.sort(RoleSpan, items, {}, lessByStart);
    return items;
}

/// Walk `root`, appending its role-tagged spans to an existing list (unsorted).
/// Lets a caller (`macro_walk`) interleave expression bodies with other spans
/// and sort the combined set once.
pub fn appendInto(root: *const AstNode, spans: *std.ArrayList(RoleSpan), allocator: Allocator) Allocator.Error!void {
    try walkNode(root, spans, allocator);
}

fn lessByStart(_: void, a: RoleSpan, b: RoleSpan) bool {
    return a.start < b.start;
}

fn append(spans: *std.ArrayList(RoleSpan), allocator: Allocator, role: Role, node: *const AstNode) Allocator.Error!void {
    try spans.append(allocator, .{ .role = role, .start = node.position.start, .end = node.position.end });
}

/// Emit a sigil span for the `[from, to)` gap (the `$`/`:` before an id). Skips
/// an empty gap, which never happens for a well-formed sigil but guards against
/// degenerate positions.
fn emitSigil(spans: *std.ArrayList(RoleSpan), allocator: Allocator, from: u32, to: u32) Allocator.Error!void {
    if (to <= from) return;
    try spans.append(allocator, .{ .role = .sigil, .start = from, .end = to });
}

fn walkNode(node: *const AstNode, spans: *std.ArrayList(RoleSpan), allocator: Allocator) Allocator.Error!void {
    switch (node.body) {
        .expression => |expr| {
            // `[...]` and `{...}` get a synthetic id ("list"/"proc") with no
            // source text: skip the callable entirely, just walk the elements.
            const synthetic = expr.meta.meta_type == .list_literal or expr.meta.meta_type == .block_literal;
            if (!synthetic) {
                // A single-term call (`$id`) carries a leading `$` between the
                // expression start and its id.
                if (expr.meta.meta_type == .single_term)
                    try emitSigil(spans, allocator, node.position.start, expr.id.position.start);
                try walkCallable(expr.id, spans, allocator);
            }
            for (expr.args) |arg| try walkNode(arg, spans, allocator);
        },
        .value_literal => try emitLiteral(node, spans, allocator),
        .scope_thunk => |inner| {
            try emitSigil(spans, allocator, node.position.start, inner.position.start);
            try walkScopeRef(inner, spans, allocator);
        },
        .err => {},
    }
}

/// The id of an expression. A leaf identifier is the operator; a nested
/// expression (`$(...)`) is walked as its own subtree.
fn walkCallable(id: *const AstNode, spans: *std.ArrayList(RoleSpan), allocator: Allocator) Allocator.Error!void {
    switch (id.body) {
        .value_literal => |v| switch (v) {
            .string => try append(spans, allocator, .operator, id),
            else => try emitLiteral(id, spans, allocator),
        },
        else => try walkNode(id, spans, allocator),
    }
}

/// A value literal as a value (argument). The `quote` field is the only thing
/// separating a quoted string from a bare identifier once parsed.
fn emitLiteral(node: *const AstNode, spans: *std.ArrayList(RoleSpan), allocator: Allocator) Allocator.Error!void {
    if (node.quote != null) {
        // Widen the content span by one byte each side to cover the delimiters.
        try spans.append(allocator, .{
            .role = .string,
            .start = node.position.start - 1,
            .end = node.position.end + 1,
        });
        return;
    }
    switch (node.body.value_literal) {
        .int, .float => try append(spans, allocator, .number, node),
        .string => try append(spans, allocator, .identifier, node),
        else => {},
    }
}

/// The term behind a `:`. A bare identifier is the scope reference; anything
/// else (`:5`, `:(...)`) falls back to ordinary handling.
fn walkScopeRef(inner: *const AstNode, spans: *std.ArrayList(RoleSpan), allocator: Allocator) Allocator.Error!void {
    switch (inner.body) {
        .value_literal => |v| {
            if (v == .string and inner.quote == null)
                try append(spans, allocator, .scope_ref, inner)
            else
                try emitLiteral(inner, spans, allocator);
        },
        else => try walkNode(inner, spans, allocator),
    }
}

/// The deepest node whose source span contains `byte`, or null if `byte` falls
/// outside `root`. Skips synthetic sugar ids, which have no source text.
pub fn nodeAt(root: *const AstNode, byte: u32) ?*const AstNode {
    if (byte < root.position.start or byte >= root.position.end) return null;

    switch (root.body) {
        .expression => |expr| {
            const synthetic = expr.meta.meta_type == .list_literal or expr.meta.meta_type == .block_literal;
            if (!synthetic) {
                if (nodeAt(expr.id, byte)) |hit| return hit;
            }
            for (expr.args) |arg| {
                if (nodeAt(arg, byte)) |hit| return hit;
            }
        },
        .scope_thunk => |inner| {
            if (nodeAt(inner, byte)) |hit| return hit;
        },
        else => {},
    }
    return root;
}

/// If `byte` falls on the bare identifier behind a `:` scope thunk, return that
/// inner identifier node; otherwise null. This is what lets a caller tell a
/// scope reference (`:x`) apart from a bare identifier used as a value, since
/// `nodeAt` collapses both to the same identifier node.
///
/// Only a bare-identifier target qualifies, because that is the only key known
/// statically. A computed key like `:(concat "a" b)` is valid syntax and is
/// descended into normally (so the cursor can land on names inside it), but the
/// `:` resolves its key at runtime, so there is nothing to point at from the
/// thunk itself.
pub fn scopeRefAt(root: *const AstNode, byte: u32) ?*const AstNode {
    if (byte < root.position.start or byte >= root.position.end) return null;

    switch (root.body) {
        .expression => |expr| {
            const synthetic = expr.meta.meta_type == .list_literal or expr.meta.meta_type == .block_literal;
            if (!synthetic) {
                if (scopeRefAt(expr.id, byte)) |hit| return hit;
            }
            for (expr.args) |arg| {
                if (scopeRefAt(arg, byte)) |hit| return hit;
            }
        },
        .scope_thunk => |inner| {
            if (byte >= inner.position.start and byte < inner.position.end and
                isBareIdentifier(inner))
                return inner;
            if (scopeRefAt(inner, byte)) |hit| return hit;
        },
        else => {},
    }
    return null;
}

/// A value literal that is a bare identifier (unquoted string), the form a
/// scope reference or callable name takes once parsed.
pub fn isBareIdentifier(node: *const AstNode) bool {
    return node.body == .value_literal and
        node.body.value_literal == .string and
        node.quote == null;
}

// Tests

const parser = lish.parser;

fn collectRoles(source: []const u8, allocator: Allocator) ![]RoleSpan {
    const root = try parser.parse(allocator, source);
    return collect(root, allocator);
}

test "operator, number, and identifier roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(+ 1 foo)" -> operator "+", number "1", identifier "foo".
    const spans = try collectRoles("(+ 1 foo)", a);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqual(Role.operator, spans[0].role);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start);
    try std.testing.expectEqual(Role.number, spans[1].role);
    try std.testing.expectEqual(Role.identifier, spans[2].role);
    try std.testing.expectEqual(@as(u32, 5), spans[2].start);
}

test "string literal distinguished from identifier by quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spans = try collectRoles("(f \"hi\" bye)", a);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqual(Role.operator, spans[0].role);
    try std.testing.expectEqual(Role.string, spans[1].role);
    try std.testing.expectEqual(Role.identifier, spans[2].role);
}

test "scope thunk emits a sigil then a scope_ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spans = try collectRoles("(when :hp)", a);
    // operator "when", sigil ":", scope_ref "hp"
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqual(Role.operator, spans[0].role);
    try std.testing.expectEqual(Role.sigil, spans[1].role);
    try std.testing.expectEqual(@as(u32, 6), spans[1].start);
    try std.testing.expectEqual(@as(u32, 7), spans[1].end);
    try std.testing.expectEqual(Role.scope_ref, spans[2].role);
    try std.testing.expectEqual(@as(u32, 7), spans[2].start);
}

test "list-literal sugar emits no operator for its synthetic id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "[1 2]" is sugar for (list 1 2): the synthetic "list" id must not appear.
    const spans = try collectRoles("[1 2]", a);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(Role.number, spans[0].role);
    try std.testing.expectEqual(Role.number, spans[1].role);
}

test "single-term call emits a sigil then an operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spans = try collectRoles("$now", a);
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(Role.sigil, spans[0].role);
    try std.testing.expectEqual(@as(u32, 0), spans[0].start);
    try std.testing.expectEqual(@as(u32, 1), spans[0].end);
    try std.testing.expectEqual(Role.operator, spans[1].role);
    try std.testing.expectEqual(@as(u32, 1), spans[1].start);
}

test "nodeAt finds the operator id node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try parser.parse(a, "(foo bar)");
    const hit = nodeAt(root, 2) orelse return error.NoNode; // inside "foo"
    try std.testing.expect(hit.body == .value_literal);
    try std.testing.expectEqualStrings("foo", hit.body.value_literal.string);
}

test "nodeAt finds a nested argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try parser.parse(a, "(foo bar)");
    const hit = nodeAt(root, 6) orelse return error.NoNode; // inside "bar"
    try std.testing.expect(hit.body == .value_literal);
    try std.testing.expectEqualStrings("bar", hit.body.value_literal.string);
}

test "nodeAt outside the tree returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try parser.parse(a, "(foo)");
    try std.testing.expect(nodeAt(root, 99) == null);
}

test "scopeRefAt returns the bare identifier behind a colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(when :hp)" — ":" at 6, "hp" at [7,9).
    const root = try parser.parse(a, "(when :hp)");
    const hit = scopeRefAt(root, 7) orelse return error.NoScopeRef; // inside "hp"
    try std.testing.expect(hit.body == .value_literal);
    try std.testing.expectEqualStrings("hp", hit.body.value_literal.string);
}

test "scopeRefAt is null on a bare identifier with no colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(foo bar)" — "bar" is a plain argument, not a scope reference.
    const root = try parser.parse(a, "(foo bar)");
    try std.testing.expect(scopeRefAt(root, 6) == null);
}

test "scopeRefAt is null on a computed key but still descends into it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ":(f x)" — the ":" key is computed; the "f"/"x" inside are not scope refs.
    const root = try parser.parse(a, ":(f x)");
    try std.testing.expect(scopeRefAt(root, 2) == null); // on "f"
    try std.testing.expect(scopeRefAt(root, 4) == null); // on "x"
}
