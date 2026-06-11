//! lish-lsp entry point. Reads LSP messages from stdin, writes responses to
//! stdout. Each message is framed with a `Content-Length: N\r\n\r\n` header
//! followed by a JSON body of exactly N bytes.
//!
//! See https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

const std = @import("std");
const lish = @import("lish");
const protocol = @import("protocol.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_file = std.Io.File.stdin().reader(io, &.{});
    var stdout_file = std.Io.File.stdout().writer(io, &.{});
    const stdin = &stdin_file.interface;
    const stdout = &stdout_file.interface;

    var stderr_file = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_file.interface;
    stderr.writeAll("lish-lsp: starting\n") catch {};
    stderr.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (true) {
        const arena_alloc = arena.allocator();

        const body = protocol.readMessage(stdin, arena_alloc) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        // For now, log every message body to stderr for visibility while we
        // build out the dispatch. This goes away once we actually parse +
        // route them.
        stderr.print("lish-lsp: rx {d} bytes\n", .{body.len}) catch {};
        stderr.flush() catch {};

        _ = stdout;

        // Reset arena between iterations to avoid unbounded growth as the
        // editor sends thousands of messages over a session.
        _ = arena.reset(.retain_capacity);
    }
}
