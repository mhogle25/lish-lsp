pub const packages = struct {
    pub const @"../lish-zig" = struct {
        pub const build_root = "/home/plank/dev/projects/lish-lsp/../lish-zig";
        pub const build_zig = @import("../lish-zig");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "lish", "../lish-zig" },
};
