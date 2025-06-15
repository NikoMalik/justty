const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "pixman",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkSystemLibrary("pthread");

    lib.addIncludePath(b.path("upstream"));
    lib.addIncludePath(b.path("upstream/pixman"));
    lib.addIncludePath(b.path("include"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",

        "-flto",
        "-ffunction-sections",
        "-fdata-sections",

        "-DHAVE_SIGACTION=1",
        "-DHAVE_ALARM=1",
        "-DHAVE_MPROTECT=1",
        "-DHAVE_GETPAGESIZE=1",
        "-DHAVE_MMAP=1",
        "-DHAVE_GETISAX=1",
        "-DHAVE_GETTIMEOFDAY=1",

        "-DHAVE_FENV_H=1",
        "-DHAVE_SYS_MMAN_H=1",
        "-DHAVE_UNISTD_H=1",

        "-DSIZEOF_LONG=8",
        "-DPACKAGE=foo",
        "-DHAVE_PTHREADS=1",

        "-DHAVE_POSIX_MEMALIGN=1",

        // There is ubsan
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    lib.addCSourceFiles(.{
        .root = b.path("upstream/"),
        .flags = flags.items,
        .files = srcs,
    });

    lib.installHeader(b.path("include/pixman-version.h"), "pixman-version.h");
    lib.installHeadersDirectory(
        b.path("upstream/pixman"),
        "pixman",
        .{
            .exclude_extensions = &.{
                ".build",
                ".c",
                ".cc",
                ".hh",
                ".in",
                ".py",
                ".rs",
                ".rl",
                ".S",
                ".ttf",
                ".txt",
            },
            .include_extensions = &.{
                ".h",
            },
        },
    );

    b.installArtifact(lib);
}

const srcs = &.{
    "pixman/pixman.c",
    "pixman/pixman-access.c",
    "pixman/pixman-access-accessors.c",
    "pixman/pixman-bits-image.c",
    "pixman/pixman-combine32.c",
    "pixman/pixman-combine-float.c",
    "pixman/pixman-conical-gradient.c",
    "pixman/pixman-filter.c",
    "pixman/pixman-x86.c",
    "pixman/pixman-mips.c",
    "pixman/pixman-arm.c",
    "pixman/pixman-ppc.c",
    "pixman/pixman-edge.c",
    "pixman/pixman-riscv.c",
    "pixman/pixman-edge-accessors.c",
    "pixman/pixman-fast-path.c",
    "pixman/pixman-glyph.c",
    "pixman/pixman-general.c",
    "pixman/pixman-gradient-walker.c",
    "pixman/pixman-image.c",
    "pixman/pixman-implementation.c",
    "pixman/pixman-linear-gradient.c",
    "pixman/pixman-matrix.c",
    "pixman/pixman-noop.c",
    "pixman/pixman-radial-gradient.c",
    "pixman/pixman-region16.c",
    "pixman/pixman-region32.c",
    "pixman/pixman-solid-fill.c",
    "pixman/pixman-trap.c",
    "pixman/pixman-utils.c",
};
