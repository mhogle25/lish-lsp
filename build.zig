const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lish_dep = b.dependency("lish", .{
        .target = target,
        .optimize = optimize,
    });
    const lish_mod = lish_dep.module("lish");

    // Reusable library surface (src/root.zig): the LSP analysis engines +
    // plumbing that a sibling server (folio-lsp) imports as `lish_lsp`. Excludes
    // server.zig / main.zig, which are private to this binary. The binary itself
    // also imports it, so the library compiles exactly once.
    const lib_mod = b.addModule("lish_lsp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "lish", .module = lish_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "lish-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lish", .module = lish_mod },
                .{ .name = "lish_lsp", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the lish LSP server (stdio)");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lish", .module = lish_mod },
                .{ .name = "lish_lsp", .module = lib_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run lish-lsp tests");
    test_step.dependOn(&run_tests.step);

    // Test the reusable library surface through root.zig. (Until server.zig is
    // rewired to import the module in step 2, the library's tests also run via
    // the main.zig graph above; the duplication is transient.)
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lish", .module = lish_mod },
            },
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);
}
