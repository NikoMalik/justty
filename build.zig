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

fn addDep(
    artifact: *std.Build.Step.Compile,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    artifact.addIncludePath(b.path("./include"));
    artifact.addIncludePath(b.path("./config/"));
    artifact.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

    // artifact.linkSystemLibrary("freetype2");
    // artifact.linkSystemLibrary("fontconfig");
    // artifact.linkSystemLibrary("harfbuzz");
    // artifact.linkSystemLibrary("pixman-1");
    artifact.linkSystemLibrary("xcb");
    artifact.linkSystemLibrary("xinerama");
    artifact.linkSystemLibrary("xcb-cursor");
    artifact.linkSystemLibrary("xcb-keysyms");
    artifact.linkSystemLibrary("xcb-render");
    artifact.linkSystemLibrary("xkbcommon");
    artifact.linkSystemLibrary("xcb-renderutil");
    artifact.linkSystemLibrary("xcb-xrm");
    artifact.linkSystemLibrary("xcb-shm");
    artifact.linkSystemLibrary2("expat", .{ .preferred_link_mode = .static });

    artifact.linkLibCpp();
    artifact.linkLibC();
    const HWY_AVX3_SPR: c_int = 1 << 4;
    const HWY_AVX3_ZEN4: c_int = 1 << 6;
    const HWY_AVX3_DL: c_int = 1 << 7;
    const HWY_AVX3: c_int = 1 << 8;

    const HWY_DISABLED_TARGETS: c_int = HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;
    artifact.addCSourceFiles(.{
        .files = &.{
            "justty_simdutf.cpp",
        },
        .flags = if (artifact.rootModuleTarget().cpu.arch == .x86_64) &.{
            b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            "-O3",
            "-march=native",
            "-flto",
            "-fno-exceptions",
            "-DNDEBUG",
            "-std=c++17",
            "-ffunction-sections",
            "-fdata-sections",
        } else &.{
            "-O3",
            "-march=native",
            "-flto",
            "-fno-exceptions",
            "-DNDEBUG",
            "-std=c++17",
            "-ffunction-sections",
            "-fdata-sections",
        },
    });

    // if (b.systemIntegrationOption("simdutf", .{})) {
    //     artifact.linkSystemLibrary2("simdutf", .{});
    // } else {
    if (b.lazyDependency("simdutf", .{
        .target = target,
        .optimize = optimize,
    })) |simdutf_dep| {
        artifact.linkLibrary(simdutf_dep.artifact("simdutf"));
        artifact.addIncludePath(simdutf_dep.path("vendor"));
    }

    if (b.lazyDependency("brotli", .{
        .target = target,
        .optimize = optimize,
    })) |brotli_dep| {
        artifact.linkLibrary(brotli_dep.artifact("brotli"));
        artifact.addIncludePath(brotli_dep.path("upstream/c"));
        artifact.addIncludePath(brotli_dep.path("upstream/c/include"));
    }

    if (b.lazyDependency("zlib", .{
        .target = target,
        .optimize = optimize,
    })) |zlib_dep| {
        artifact.linkLibrary(zlib_dep.artifact("z"));
    }

    if (b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
    })) |freetype_dep| {
        artifact.linkLibrary(freetype_dep.artifact("freetype"));
        artifact.addIncludePath(freetype_dep.path("upstream"));

        artifact.addIncludePath(freetype_dep.path("upstream/include"));
    }

    if (b.lazyDependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    })) |harfbuzz_dep| {
        artifact.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    }

    if (b.lazyDependency("fontconfig", .{
        .target = target,
        .optimize = optimize,
    })) |fontconfig_dep| {
        artifact.linkLibrary(fontconfig_dep.artifact("fontconfig"));
        artifact.addIncludePath(fontconfig_dep.path("override/include"));
        artifact.addIncludePath(fontconfig_dep.path("upstream/"));
    }

    if (b.lazyDependency("pixman", .{
        .target = target,
        .optimize = optimize,
    })) |pixman_dep| {
        artifact.linkLibrary(pixman_dep.artifact("pixman"));
        artifact.addIncludePath(pixman_dep.path("upstream"));
        artifact.addIncludePath(pixman_dep.path("upstream/pixman"));
        artifact.addIncludePath(pixman_dep.path("include"));
    }

    // }

    // if (b.systemIntegrationOption("highway", .{})) {
    //     artifact.linkSystemLibrary2("highway", .{});
    // } else {
    if (b.lazyDependency("highway", .{
        .target = target,
        .optimize = optimize,
    })) |highway_dep| {
        artifact.linkLibrary(highway_dep.artifact("highway"));
        artifact.addIncludePath(highway_dep.path("hwy"));
    }
    // }

    // if (b.systemIntegrationOption("fcft", .{})) {
    //     artifact.linkSystemLibrary2("fcft", .{});
    // } else {
    if (b.lazyDependency("fcft", .{
        .target = target,
        .optimize = optimize,
    })) |fcft_dep| {
        artifact.linkLibrary(fcft_dep.artifact("fcft"));
        artifact.addIncludePath(fcft_dep.path("fcft"));
        artifact.addIncludePath(fcft_dep.path(""));
    }
    // }
}

comptime {
    requireZig("0.14.0");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    addDep(exe, b, target, optimize);

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
    addDep(unit_tests, b, target, optimize);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    run_step.dependOn(&run_exe.step);
}
