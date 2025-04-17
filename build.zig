const std = @import("std");
const builtin = @import("builtin");

inline fn requireZig(comptime required_zig: []const u8) void {
    const current_vsn = builtin.zig_version;
    const required_vsn = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_vsn.major != required_vsn.major or
        current_vsn.minor != required_vsn.minor)
    {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the required build version of v{}",
            .{ current_vsn, required_vsn },
        ));
    }
}

comptime {
    requireZig("0.14.0");
}

const prefix = "/usr/local";
const X11LIB = "/usr/lib64/X11";
const X11INC = "/usr/include/X11";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    //dependencies
    // ==============================================================//
    //
    //
    //
    //
    //
    // ==============================================================//

    // const lib_mod = b.addModule("justty", .{
    //     .root_source_file = b.path("root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });

    const exe = b.addExecutable(.{
        .name = "justty",
        .use_llvm = true,
        .use_lld = true,
        .root_source_file = b.path("justty.zig"),
        // .root_module = lib_mod,
        .target = target,
        .link_libc = true,
        .optimize = optimize,
    });
    exe.addIncludePath(b.path("./include/"));
    exe.addIncludePath(b.path("./config/"));
    exe.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    exe.linkSystemLibrary("freetype2");
    exe.linkSystemLibrary("fontconfig");
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("xinerama");
    exe.linkSystemLibrary("freetype");
    exe.linkSystemLibrary("Xft");
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "run app");

    const test_step = b.step("test", "Run library tests");

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("justty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    unit_tests.addIncludePath(b.path("./include/"));
    unit_tests.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    unit_tests.linkSystemLibrary("freetype2");
    unit_tests.linkSystemLibrary("fontconfig");
    unit_tests.linkSystemLibrary("X11");
    unit_tests.linkSystemLibrary("xinerama");
    unit_tests.linkSystemLibrary("freetype");
    unit_tests.linkSystemLibrary("Xft");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    run_step.dependOn(&run_exe.step);
}
