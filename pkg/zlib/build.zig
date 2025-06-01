const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "z",
        .target = target,
        .optimize = optimize,
    });
    lib.addIncludePath(b.path("upstream"));

    lib.linkLibC();
    lib.addCSourceFiles(.{
        .root = b.path("upstream/"),
        .files = &.{
            "adler32.c",
            "crc32.c",
            "deflate.c",
            "infback.c",
            "inffast.c",
            "inflate.c",
            "inftrees.c",
            "trees.c",
            "zutil.c",
            "compress.c",
            "uncompr.c",
            "gzclose.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
        },
        .flags = &.{
            "-O3",
            "-march=native",

            "-flto",
            "-ffunction-sections",
            "-fdata-sections",

            "-DHAVE_SYS_TYPES_H",
            "-DHAVE_STDINT_H",
            "-DHAVE_STDDEF_H",
            "-DZ_HAVE_UNISTD_H",
        },
    });
    lib.installHeadersDirectory(b.path("upstream/"), "upstream/", .{
        .include_extensions = &.{
            ".h",
        },
    });
    b.installArtifact(lib);
}
