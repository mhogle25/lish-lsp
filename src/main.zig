//! lish-lsp entry point. Reads LSP messages from stdin, writes responses to
//! stdout. Each message is framed with a `Content-Length: N\r\n\r\n` header
//! followed by a JSON body of exactly N bytes.
//!
//! See https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

const std = @import("std");
const lish = @import("lish");
const protocol = @import("protocol.zig");
const Server = @import("server.zig").Server;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_file = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_file = std.Io.File.stdout().writer(io, &.{});
    var stderr_file = std.Io.File.stderr().writer(io, &.{});
    const stdin = &stdin_file.interface;
    const stdout = &stdout_file.interface;
    const stderr = &stderr_file.interface;

    stderr.writeAll("lish-lsp: starting\n") catch {};
    stderr.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var server = Server.init(allocator, stdout, stderr);
    server.io = io;
    defer server.deinit();

    while (!server.should_exit) {
        const arena_alloc = arena.allocator();

        const body = protocol.readMessage(stdin, arena_alloc) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        server.handle(body, arena_alloc) catch |err| {
            stderr.print("lish-lsp: handle error: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
        };

        _ = arena.reset(.retain_capacity);
    }

    return if (server.exit_was_unclean) 1 else 0;
}

test {
    std.testing.refAllDecls(@This());
}
