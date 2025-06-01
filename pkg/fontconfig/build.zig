const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "fontconfig",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkSystemLibrary("pthread");
    const freetype_dep = b.lazyDependency("freetype", .{ .target = target, .optimize = optimize });
    lib.linkLibrary(freetype_dep.?.artifact("freetype"));

    lib.addIncludePath(b.path("override/include"));
    lib.addIncludePath(b.path("upstream/"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-O3",
        "-march=native",

        "-flto",
        "-ffunction-sections",
        "-fdata-sections",

        "-DHAVE_DIRENT_H",
        "-DHAVE_FCNTL_H",
        "-DHAVE_STDLIB_H",
        "-DHAVE_STRING_H",
        "-DHAVE_UNISTD_H",
        "-DHAVE_SYS_PARAM_H",

        "-DHAVE_MKSTEMP",
        //"-DHAVE_GETPROGNAME",
        //"-DHAVE_GETEXECNAME",
        "-DHAVE_RAND",
        "-DHAVE_RANDOM_R",
        "-DHAVE_VPRINTF",

        "-DHAVE_FT_GET_BDF_PROPERTY",
        "-DHAVE_FT_GET_PS_FONT_INFO",
        "-DHAVE_FT_HAS_PS_GLYPH_NAMES",
        "-DHAVE_FT_GET_X11_FONT_FORMAT",
        "-DHAVE_FT_DONE_MM_VAR",

        "-DHAVE_POSIX_FADVISE",

        "-DFLEXIBLE_ARRAY_MEMBER",
        "-DHAVE_PTHREAD",

        "-DHAVE_FSTATFS",
        "-DHAVE_FSTATVFS",
        "-DHAVE_GETOPT",
        "-DHAVE_GETOPT_LONG",
        "-DHAVE_LINK",
        "-DHAVE_LRAND48",
        "-DHAVE_LSTAT",
        "-DHAVE_MKDTEMP",
        "-DHAVE_MKOSTEMP",
        "-DHAVE__MKTEMP_S",
        "-DHAVE_MMAP",
        "-DHAVE_PTHREAD",
        "-DHAVE_RANDOM",
        "-DHAVE_RAND_R",
        "-DHAVE_READLINK",
        "-DHAVE_SYS_MOUNT_H",
        "-DHAVE_SYS_STATVFS_H",

        "-DFC_CACHEDIR=\"/var/cache/fontconfig\"",
        "-DFC_TEMPLATEDIR=\"/usr/share/fontconfig/conf.avail\"",
        "-DFONTCONFIG_PATH=\"/etc/fonts\"",
        "-DCONFIGDIR=\"/usr/local/fontconfig/conf.d\"",
        "-DFC_DEFAULT_FONTS=\"<dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>\"",

        "-DHAVE_STDATOMIC_PRIMITIVES",

        "-DFC_GPERF_SIZE_T=size_t",

        "-Wno-implicit-function-declaration",
        "-Wno-int-conversion",

        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });
    switch (target.result.ptrBitWidth()) {
        32 => try flags.appendSlice(&.{
            "-DSIZEOF_VOID_P=4",
            "-DALIGNOF_VOID_P=4",
        }),

        64 => try flags.appendSlice(&.{
            "-DSIZEOF_VOID_P=8",
            "-DALIGNOF_VOID_P=8",
        }),

        else => @panic("unsupported arch"),
    }
    if (target.result.os.tag == .linux) {
        try flags.appendSlice(&.{
            "-DHAVE_SYS_STATFS_H",
            "-DHAVE_SYS_VFS_H",
        });
    }

    lib.addCSourceFiles(.{
        .root = b.path("upstream/"),
        .files = srcs,
        .flags = flags.items,
    });

    // lib.installHeader(b.path("override/include"), "override/include/fontconfig.h");

    lib.installHeadersDirectory(
        b.path("upstream/fontconfig/"),
        "fontconfig",
        .{ .include_extensions = &.{
            ".h",
        } },
    );

    b.installArtifact(lib);
}

const srcs = &.{
    "src/fcatomic.c",
    "src/fccache.c",
    "src/fccfg.c",
    "src/fccharset.c",
    "src/fccompat.c",
    "src/fcdbg.c",
    "src/fcdefault.c",
    "src/fcdir.c",
    "src/fcformat.c",
    "src/fcfreetype.c",
    "src/fcfs.c",
    "src/fcptrlist.c",
    "src/fchash.c",
    "src/fcinit.c",
    "src/fclang.c",
    "src/fclist.c",
    "src/fcmatch.c",
    "src/fcmatrix.c",
    "src/fcname.c",
    "src/fcobjs.c",
    "src/fcpat.c",
    "src/fcrange.c",
    "src/fcserialize.c",
    "src/fcstat.c",
    "src/fcstr.c",
    "src/fcweight.c",
    "src/fcxml.c",
    "src/ftglue.c",
};
