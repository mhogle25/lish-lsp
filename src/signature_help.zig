//! `textDocument/signatureHelp`: show the call signature and highlight the
//! parameter the cursor is currently filling.
//!
//! Finds the innermost call expression the cursor sits in (past the op name, in
//! the argument region), reads the op's structured signature, and reports the
//! active parameter as the count of arguments already completed before the
//! cursor (clamped onto the last parameter, so a variadic stays highlighted).

const std = @import("std");
const lish = @import("lish");
const lish_registry = @import("lish_registry.zig");
const Language = @import("semantic_tokens.zig").Language;

const Allocator = std.mem.Allocator;
const AstNode = lish.ast.AstNode;
const LishRegistry = lish_registry.LishRegistry;

/// Signature help for one call. `params` are the parameter display names (the
/// client highlights `params[active]` within `label`).
pub const Help = struct {
    label: []const u8,
    params: []const []const u8,
    active: u32,
};

const Call = struct {
    name: []const u8,
    active: u32,
};

/// Compute signature help at byte offset `cursor`, or null if the cursor is not
/// inside a known call's arguments.
pub fn at(
    source: []const u8,
    cursor: u32,
    registry: *const LishRegistry,
    language: Language,
    allocator: Allocator,
) Allocator.Error!?Help {
    const call = switch (language) {
        .expression => blk: {
            const root = try lish.parser.parse(allocator, source);
            break :blk findCall(root, cursor, registry);
        },
        .macro => blk: {
            const module = try lish.macro_parser.parseMacroModule(allocator, source);
            for (module.macros) |node| {
                const macro = switch (node) {
                    .macro => |m| m,
                    .err => continue,
                };
                if (cursor < macro.body.position.start or cursor > macro.body.position.end) continue;
                break :blk findCall(macro.body, cursor, registry);
            }
            break :blk null;
        },
    } orelse return null;

    var label: std.Io.Writer.Allocating = .init(allocator);
    var params: []const []const u8 = &.{};

    if (registry.registry.getOperation(call.name)) |op| {
        op.signature.render(&label.writer, call.name) catch return error.OutOfMemory;
        const names = try allocator.alloc([]const u8, op.signature.params.len);
        for (op.signature.params, 0..) |param, i| names[i] = param.name;
        params = names;
    } else if (registry.registry.getMacro(call.name)) |macro| {
        macro.writeSignature(&label.writer) catch return error.OutOfMemory;
        const names = try allocator.alloc([]const u8, macro.parameters.len);
        for (macro.parameters, 0..) |param, i| names[i] = param.id;
        params = names;
    } else return null;

    const active: u32 = if (params.len == 0) 0 else @min(call.active, @as(u32, @intCast(params.len - 1)));
    return .{ .label = label.written(), .params = params, .active = active };
}

fn findCall(node: *const AstNode, cursor: u32, registry: *const LishRegistry) ?Call {
    if (!containsCursor(node, cursor)) return null;

    switch (node.body) {
        .expression => |expr| {
            // Prefer the innermost call: recurse into the argument holding the
            // cursor, then into the id (a parenthesized call sits in the id slot
            // of its enclosing top-level/single-term expression).
            if (argIndexAt(expr.args, cursor)) |i| {
                if (findCall(expr.args[i], cursor, registry)) |deeper| return deeper;
            }
            if (containsCursor(expr.id, cursor)) {
                if (findCall(expr.id, cursor, registry)) |deeper| return deeper;
            }
            // This call applies once the cursor is past the op name (in the args).
            if (cursor > expr.id.position.end) {
                if (opName(expr.id)) |name| {
                    if (registry.registry.getOperation(name) != null or registry.registry.getMacro(name) != null) {
                        return .{ .name = name, .active = activeParam(expr.args, cursor) };
                    }
                }
            }
            return null;
        },
        .scope_thunk => |inner| return findCall(inner, cursor, registry),
        else => return null,
    }
}

/// Whether `cursor` is inside `node`. An unclosed expression (missing close
/// bracket) extends to the cursor, so help still fires while the call is being
/// typed and the cursor sits in its trailing whitespace.
fn containsCursor(node: *const AstNode, cursor: u32) bool {
    if (cursor < node.position.start) return false;
    if (cursor <= node.position.end) return true;
    return node.body == .expression and node.body.expression.close_err != null;
}

fn argIndexAt(args: []const *const AstNode, cursor: u32) ?usize {
    for (args, 0..) |arg, i| {
        if (containsCursor(arg, cursor)) return i;
    }
    return null;
}

fn opName(id: *const AstNode) ?[]const u8 {
    if (id.body != .value_literal) return null;
    if (id.quote != null) return null;
    if (id.body.value_literal != .string) return null;
    return id.body.value_literal.string;
}

/// The parameter index being filled: the number of arguments that end strictly
/// before the cursor (an argument whose end is at the cursor is still being typed).
fn activeParam(args: []const *const AstNode, cursor: u32) u32 {
    var count: u32 = 0;
    for (args) |arg| {
        if (arg.position.end < cursor) count += 1;
    }
    return count;
}

// Tests

const testing = std.testing;

fn helpAt(source: []const u8, cursor: u32, allocator: Allocator) !?Help {
    var registry = try LishRegistry.init(allocator);
    defer registry.deinit();
    return at(source, cursor, &registry, .expression, allocator);
}

test "active parameter advances with the cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(clamp 0 10 )": `clamp v lo hi`; cursor in the third argument slot.
    const source = "(clamp 0 10 ";
    const help = (try helpAt(source, @intCast(source.len), a)) orelse return error.NoHelp;
    try testing.expectEqualStrings("clamp v lo hi", help.label);
    try testing.expectEqual(@as(u32, 2), help.active); // on "hi"
}

test "first parameter right after the op name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "(clamp ";
    const help = (try helpAt(source, @intCast(source.len), a)) orelse return error.NoHelp;
    try testing.expectEqual(@as(u32, 0), help.active);
    try testing.expectEqual(@as(usize, 3), help.params.len);
}

test "innermost call wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(+ 1 (clamp 0 ": cursor inside the inner clamp call (`clamp v lo hi`).
    const source = "(+ 1 (clamp 0 ";
    const help = (try helpAt(source, @intCast(source.len), a)) orelse return error.NoHelp;
    try testing.expectEqualStrings("clamp v lo hi", help.label);
    try testing.expectEqual(@as(u32, 1), help.active); // on "lo"
}

test "variadic parameter stays highlighted past the named ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(+ 1 2 3 ": `+ a b ...`; the 3rd+ args clamp onto the last param.
    const source = "(+ 1 2 3 ";
    const help = (try helpAt(source, @intCast(source.len), a)) orelse return error.NoHelp;
    try testing.expectEqual(@as(u32, 1), help.active); // clamped onto "b"
}

test "cursor on the op name yields no help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "(clam": still typing the op name.
    try testing.expect((try helpAt("(clam", 5, a)) == null);
}

test "unknown op yields no help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try helpAt("(nope 1 ", 8, a)) == null);
}
