const std = @import("std");

const Executable = struct {
    name: []const u8,
    path: []const u8,
};

const programs = [_]Executable{
    .{ .name = "key_logger", .path = "src/key_logger.zig" },
    .{ .name = "autokeys", .path = "src/autokeys.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/c.h"),
    });
    const translate_c_mod = translate_c.addModule("linux");

    for (programs) |program| {
        const exe = b.addExecutable(.{
            .name = program.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(program.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("linux", translate_c_mod);
        b.installArtifact(exe);
    }
}
