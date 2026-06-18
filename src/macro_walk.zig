//! Role-tagged spans for a `.lishmacro` module.
//!
//! A macro module is a sequence of `| name params | body` definitions. The
//! head contributes a definition (the macro name), its parameters, and the `~`
//! sigil on deferred ones; the body is an ordinary lish expression, so it reuses
//! the expression walker. The `|` bars are omitted, like brackets in expression
//! mode: clients theme delimiters themselves.

const std = @import("std");
const lish = @import("lish");
const ast_walk = @import("ast_walk.zig");

const Allocator = std.mem.Allocator;
const macro_parser = lish.macro_parser;
const AstMacroModule = macro_parser.AstMacroModule;
const RoleSpan = ast_walk.RoleSpan;

/// Walk a parsed macro module and return its role-tagged spans, sorted by start
/// offset. `source` is needed only to confirm the `~` byte before a deferred
/// parameter.
pub fn collect(module: AstMacroModule, source: []const u8, allocator: Allocator) Allocator.Error![]RoleSpan {
    var spans: std.ArrayList(RoleSpan) = .empty;
    errdefer spans.deinit(allocator);

    for (module.macros) |node| {
        const macro = switch (node) {
            .macro => |m| m,
            .err => continue,
        };

        switch (macro.id) {
            .valid => |id_data| try spans.append(allocator, .{
                .role = .definition,
                .start = id_data.position.start,
                .end = id_data.position.end,
            }),
            .err => {},
        }

        for (macro.parameters) |param_node| {
            const param = switch (param_node) {
                .valid => |p| p,
                .err => continue,
            };
            // A deferred parameter is written `~name`; tag the leading `~` as a
            // sigil when it is actually there (it sits one byte before the name).
            if (param.param_type == .deferred and param.position.start > 0 and
                source[param.position.start - 1] == lish.token.DEFERRED)
            {
                try spans.append(allocator, .{ .role = .sigil, .start = param.position.start - 1, .end = param.position.start });
            }
            try spans.append(allocator, .{
                .role = .parameter,
                .start = param.position.start,
                .end = param.position.end,
            });
        }

        try ast_walk.appendInto(macro.body, &spans, allocator);
    }

    const items = try spans.toOwnedSlice(allocator);
    std.mem.sort(RoleSpan, items, {}, lessByStart);
    return items;
}

fn lessByStart(_: void, a: RoleSpan, b: RoleSpan) bool {
    return a.start < b.start;
}

// Tests

const testing = std.testing;
const Role = ast_walk.Role;

fn collectSource(source: []const u8, allocator: Allocator) ![]RoleSpan {
    const parsed = try macro_parser.parseMacroModuleWithComments(allocator, source);
    return collect(parsed.module, source, allocator);
}

test "macro head: definition, value param, body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "| double x | * :x 2"
    const spans = try collectSource("| double x | * :x 2", a);
    // definition "double", parameter "x", operator "*", sigil ":", scope_ref "x", number "2"
    try testing.expectEqual(@as(usize, 6), spans.len);
    try testing.expectEqual(Role.definition, spans[0].role);
    try testing.expectEqual(@as(u32, 2), spans[0].start); // after "| "
    try testing.expectEqual(Role.parameter, spans[1].role);
    try testing.expectEqual(Role.operator, spans[2].role);
    try testing.expectEqual(Role.sigil, spans[3].role);
    try testing.expectEqual(Role.scope_ref, spans[4].role);
    try testing.expectEqual(Role.number, spans[5].role);
}

test "deferred parameter gets a ~ sigil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "| run ~body | if :body 1"
    const spans = try collectSource("| run ~body | if :body 1", a);
    try testing.expectEqual(Role.definition, spans[0].role); // run
    // The "~" sigil immediately precedes "body".
    try testing.expectEqual(Role.sigil, spans[1].role);
    try testing.expectEqual(Role.parameter, spans[2].role); // body
    try testing.expectEqual(@as(u32, spans[1].end), spans[2].start);
}

test "multiple macros each contribute a definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spans = try collectSource("| a x | + :x 1 | b y | + :y 2", a);
    var definitions: usize = 0;
    for (spans) |s| {
        if (s.role == .definition) definitions += 1;
    }
    try testing.expectEqual(@as(usize, 2), definitions);
}

test "empty source yields no spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const spans = try collectSource("", a);
    try testing.expectEqual(@as(usize, 0), spans.len);
}
