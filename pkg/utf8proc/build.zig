const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "utf8proc",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    lib.addIncludePath(b.path("upstream/"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",
        "-DUTF8PROC_EXPORTS",
        "-std=c99",
    });
    defer flags.deinit();
    lib.addCSourceFiles(.{
        .root = b.path(""),
        .files = &.{
            "upstream/utf8proc.c",
        },
        .flags = flags.items,
    });

    lib.installHeadersDirectory(
        b.path("upstream/"),
        "utf8proc",
        .{ .include_extensions = &.{".h"} },
    );
    b.installArtifact(lib);
}
