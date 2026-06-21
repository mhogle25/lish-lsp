//! In-scope binding names for `:`-scope completion.
//!
//! Walks the binding-form ancestors of the cursor (`let`, `map`, `pipe`, ...),
//! reading each op's binding layout from its structured signature (param roles
//! `binding`/`body`, plus `binding_pairs` for `let`). A name introduced at an
//! earlier argument is in scope when the cursor sits in a later argument of the
//! same form, so it is offered there.

const std = @import("std");
const lish = @import("lish");
const ast_walk = @import("ast_walk.zig");
const lish_registry = @import("lish_registry.zig");

const Allocator = std.mem.Allocator;
const AstNode = lish.ast.AstNode;
const Signature = lish.Signature;
const Param = lish.Param;
const LishRegistry = lish_registry.LishRegistry;

const MAX_PARAMS = 16;

/// Collect the binding names in scope at `cursor` within an expression tree,
/// innermost first. Names are slices into the source the tree was parsed from.
pub fn collect(
    root: *const AstNode,
    cursor: u32,
    registry: *const LishRegistry,
    allocator: Allocator,
) Allocator.Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer names.deinit(allocator);
    try collectInto(root, cursor, registry, &names, allocator);
    return names.toOwnedSlice(allocator);
}

/// Append the in-scope binding names at `cursor` to `names` (deduped). Lets a
/// caller seed the list first (e.g. with macro head parameters).
pub fn collectInto(
    root: *const AstNode,
    cursor: u32,
    registry: *const LishRegistry,
    names: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) Allocator.Error!void {
    try walk(root, cursor, registry, names, allocator);
}

/// Append a binding name, skipping duplicates and non-identifier arguments.
pub fn appendUnique(
    names: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
    allocator: Allocator,
) Allocator.Error!void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, name);
}

fn walk(
    node: *const AstNode,
    cursor: u32,
    registry: *const LishRegistry,
    names: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) Allocator.Error!void {
    // End is inclusive: while typing, the cursor sits at the end of the (often
    // unclosed) node it is in.
    if (cursor < node.position.start or cursor > node.position.end) return;

    switch (node.body) {
        .expression => |expr| {
            const cursor_arg = argIndexAt(expr.args, cursor);
            if (opName(expr.id)) |name| {
                if (registry.registry.getOperation(name)) |op| {
                    try collectBindings(op.signature, expr.args, cursor_arg, names, allocator);
                }
            }
            if (cursor_arg) |i| {
                try walk(expr.args[i], cursor, registry, names, allocator);
            } else {
                try walk(expr.id, cursor, registry, names, allocator);
            }
        },
        .scope_thunk => |inner| try walk(inner, cursor, registry, names, allocator),
        else => {},
    }
}

/// The index of the argument whose span contains `cursor`, or null (cursor on
/// the op id, a bracket, or whitespace).
fn argIndexAt(args: []const *const AstNode, cursor: u32) ?usize {
    for (args, 0..) |arg, i| {
        if (cursor >= arg.position.start and cursor <= arg.position.end) return i;
    }
    return null;
}

fn opName(id: *const AstNode) ?[]const u8 {
    if (ast_walk.isBareIdentifier(id)) return id.body.value_literal.string;
    return null;
}

/// Append the names this form binds that are in scope at `cursor_arg`: a binding
/// at argument `i` is in scope when `i < cursor_arg`.
fn collectBindings(
    signature: Signature,
    args: []const *const AstNode,
    cursor_arg: ?usize,
    names: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) Allocator.Error!void {
    const k = cursor_arg orelse return;
    if (!hasBinding(signature)) return;

    if (signature.binding_pairs) {
        // `let name value ... body`: a name at even index `i` (whose value is at
        // `i + 1`) is in scope in any later argument except its own value slot.
        var i: usize = 0;
        while (i < k and i + 1 < args.len) : (i += 2) {
            if (i + 1 != k) try appendArg(args[i], names, allocator);
        }
        return;
    }

    var roles: [MAX_PARAMS]Param.Role = undefined;
    assignRoles(signature.params, args.len, &roles);
    var i: usize = 0;
    while (i < k and i < MAX_PARAMS) : (i += 1) {
        if (roles[i] == .binding) try appendArg(args[i], names, allocator);
    }
}

fn hasBinding(signature: Signature) bool {
    for (signature.params) |param| {
        if (param.role == .binding) return true;
    }
    return false;
}

/// Map each argument index to the role of the parameter covering it, accounting
/// for an absent leading optional and a trailing variadic.
fn assignRoles(params: []const Param, arg_count: usize, roles: []Param.Role) void {
    const n = @min(arg_count, roles.len);
    for (roles[0..n]) |*role| role.* = .value;

    var non_optional: usize = 0;
    for (params) |param| {
        if (param.arity != .optional) non_optional += 1;
    }
    const optional_present = arg_count > non_optional;

    var arg: usize = 0;
    for (params) |param| {
        if (arg >= n) break;
        if (param.arity == .optional and !optional_present) continue;
        roles[arg] = param.role;
        arg += 1;
        if (param.arity == .variadic) {
            while (arg < n) : (arg += 1) roles[arg] = param.role;
        }
    }
}

fn appendArg(
    arg: *const AstNode,
    names: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
) Allocator.Error!void {
    if (!ast_walk.isBareIdentifier(arg)) return;
    try appendUnique(names, arg.body.value_literal.string, allocator);
}

// Tests

const testing = std.testing;
const parser = lish.parser;

fn namesAt(source: []const u8, cursor: u32, allocator: Allocator) ![]const []const u8 {
    var registry = try LishRegistry.init(allocator);
    defer registry.deinit();
    const root = try parser.parse(allocator, source);
    return collect(root, cursor, &registry, allocator);
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

test "let binding is in scope in the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(let n 5 (+ :n))": cursor inside the body, on the "n" of ":n".
    const source = "(let n 5 (+ :n))";
    const cursor: u32 = @intCast(std.mem.indexOf(u8, source, ":n").? + 1);
    const names = try namesAt(source, cursor, a);
    try testing.expect(has(names, "n"));
}

test "later let binding sees earlier ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(let a 1 b (+ :a) :b)": cursor in b's value, should see a (not b).
    const source = "(let a 1 b (+ :a) :b)";
    const cursor: u32 = @intCast(std.mem.indexOf(u8, source, ":a").? + 1);
    const names = try namesAt(source, cursor, a);
    try testing.expect(has(names, "a"));
    try testing.expect(!has(names, "b"));
}

test "map binds name in its body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(map x [1 2] (* :x 2))": cursor on ":x" inside the body.
    const source = "(map x [1 2] (* :x 2))";
    const cursor: u32 = @intCast(std.mem.indexOf(u8, source, ":x").? + 1);
    const names = try namesAt(source, cursor, a);
    try testing.expect(has(names, "x"));
}

test "reduce binds both accumulator and item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(reduce acc 0 it [1 2] (+ :acc :it))": both in scope in the body.
    const source = "(reduce acc 0 it [1 2] (+ :acc :it))";
    const cursor: u32 = @intCast(std.mem.indexOf(u8, source, ":acc").? + 1);
    const names = try namesAt(source, cursor, a);
    try testing.expect(has(names, "acc"));
    try testing.expect(has(names, "it"));
}

test "nested forms accumulate scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // outer let binds `total`, inner map binds `x`; both visible in the inner body.
    const source = "(let total 0 (map x [1 2] (+ :x :total)))";
    const cursor: u32 = @intCast(std.mem.indexOf(u8, source, ":x").? + 1);
    const names = try namesAt(source, cursor, a);
    try testing.expect(has(names, "x"));
    try testing.expect(has(names, "total"));
}

test "binding is not in scope in the source argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // In "(map x :here (* 2))" the cursor in arg1 (the list/source) is index 1 >
    // 0, so x is offered, an accepted minor over-offer. But on the name itself
    // (arg0) nothing is in scope.
    const source = "(map x [1] (* 2))";
    const cursor: u32 = @intCast(std.mem.indexOf(u8, source, "x").?); // on the binding name
    const names = try namesAt(source, cursor, a);
    try testing.expect(!has(names, "x"));
}

test "non-binding op contributes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "(+ 1 (* 2 3))";
    const names = try namesAt(source, 8, a);
    try testing.expectEqual(@as(usize, 0), names.len);
}
