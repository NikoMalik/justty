const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const builtin = @import("builtin");
const log = std.log;
const xlib = @import("x.zig");
const util = @import("util.zig");
const print = std.debug.print;
const xcb_font = @import("xcb_font.zig");
const signal = @import("signal.zig");
const build_options = @import("build_options");
test {
    std.testing.refAllDecls(@This());
}
const TIOCSCTTY = c.TIOCSCTTY;
const TIOCSWINSZ = c.TIOCSWINSZ;
const TIOCGWINSZ = c.TIOCGWINSZ;

pub const winsize = c.winsize;

pub const Pty = struct {
    const fd = posix.fd_t;
    extern "c" fn setsid() std.c.pid_t; // new session
    const pty = switch (builtin.os.tag) {
        .linux => @cImport({
            @cInclude("pty.h");
            @cInclude("unistd.h");
            @cInclude("pwd.h");
        }),
        else => unreachable,
    };

    const Self = @This();

    master: fd,
    slave: fd,
    pid: posix.pid_t = 0,

    pub fn open(size: winsize) !Self {
        var master_fd: fd = undefined;
        var slave_fd: fd = undefined;

        if (pty.openpty(
            &master_fd,
            &slave_fd,
            null,
            null,
            @ptrCast(&size),
        ) < 0) return error.OpenFailed;
        errdefer {
            _ = posix.system.close(master_fd);
            _ = posix.system.close(slave_fd);
        }

        const fd_flags = try posix.fcntl(master_fd, posix.F.GETFD, 0);
        _ = posix.fcntl(
            master_fd,
            posix.F.SETFD,
            fd_flags | posix.FD_CLOEXEC,
        ) catch |err| {
            log.warn("error  create fcntl on master fd err={}", .{err});
            return error.CannotCreatefcntl_masterfd;
        };

        const fd_slave_flags = try posix.fcntl(slave_fd, posix.F.GETFL, 0);
        _ = posix.fcntl(
            slave_fd,
            posix.F.SETFL,
            fd_slave_flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
        ) catch |err| {
            log.warn("error  create fcntl on slave fd err={}", .{err});
            return error.CannotCreatefcntl_slavefd;
        };
        return .{
            .master = master_fd,
            .slave = slave_fd,
        };
    }

    pub fn ttyhangup(self: *Self) !void {
        // Send SIGHUP to shell
        try posix.kill(self.master, posix.SIG.HUP);
    }

    pub fn killit(self: *Self) !void {
        try posix.kill(self.pid, posix.SIG.TERM);
    }

    pub fn write(self: *Self, str: []const u8) !usize {
        var bytes = str;
        var total_written: usize = 0;
        while (bytes.len > 0) {
            const written = try posix.write(self.master, bytes);
            total_written += written;
            bytes = bytes[written..];
        }
        return total_written;
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        return posix.read(self.master, buf);
    }

    pub fn exec(self: *Self, pid: posix.pid_t) !posix.pid_t {
        if (pid == -1) {
            return error.ForkFailed;
        }

        if (pid == 0) {
            // Child process
            // Create a new session
            // try posix.setpgid(0, 0);
            if (pty.setsid() == -1) {
                std.c._exit(1);
            }

            // Set the slave PTY as the controlling terminal
            if (pty.ioctl(self.slave, pty.TIOCSCTTY, @as(c_int, 0)) == -1) {
                std.c._exit(1);
            }

            // Redirect STDIN, STDOUT, STDERR to the slave PTY
            posix.dup2(self.slave, posix.STDIN_FILENO) catch std.c._exit(1);
            posix.dup2(self.slave, posix.STDOUT_FILENO) catch std.c._exit(1);
            posix.dup2(self.slave, posix.STDERR_FILENO) catch std.c._exit(1);
            posix.close(self.slave);

            // Reset signal handlers in the child
            var sa: posix.Sigaction = .{
                .handler = .{ .handler = posix.SIG.DFL },
                .mask = posix.empty_sigset,
                .flags = 0,
            };
            posix.sigaction(posix.SIG.ABRT, &sa, null);
            posix.sigaction(posix.SIG.ALRM, &sa, null);
            posix.sigaction(posix.SIG.BUS, &sa, null);
            posix.sigaction(posix.SIG.CHLD, &sa, null);
            posix.sigaction(posix.SIG.FPE, &sa, null);
            posix.sigaction(posix.SIG.HUP, &sa, null);
            posix.sigaction(posix.SIG.ILL, &sa, null);
            posix.sigaction(posix.SIG.INT, &sa, null);
            posix.sigaction(posix.SIG.PIPE, &sa, null);
            posix.sigaction(posix.SIG.SEGV, &sa, null);
            posix.sigaction(posix.SIG.TRAP, &sa, null);
            posix.sigaction(posix.SIG.TERM, &sa, null);
            posix.sigaction(posix.SIG.QUIT, &sa, null);

            _ = c.unsetenv("COLUMNS");
            _ = c.unsetenv("LINES");
            _ = c.setenv("TERM", &c.termname, 1);

            // Execute the shell
            const shell = getShellPath();
            std.posix.execvpeZ(shell, &.{ shell, null }, std.c.environ) catch {
                std.c._exit(1);
            };
            unreachable; // execvpeZ replaces the process
        }

        // Parent process
        posix.close(self.slave);
        self.pid = pid;
        return pid;
    }

    inline fn getShellPath() [:0]const u8 {
        if (std.posix.getenv("SHELL")) |shell| return shell;

        const uid = pty.getuid();
        const pwd = pty.getpwuid(uid);
        if (pwd != null) {
            const shell = pwd.*.pw_shell;
            return std.mem.span(shell);
        }

        return "/bin/sh";
    }

    pub fn resize(self: *Self, size: winsize) !void {
        if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0) {
            return error.IoctlResizeError;
        }
    }

    pub fn getSize(self: Pty) !winsize {
        var ws: winsize = undefined;
        if (c.ioctl(self.master, TIOCGWINSZ, @intFromPtr(&ws)) < 0)
            return error.IoctlFailed;

        return ws;
    }

    pub fn deinit(self: *Self) void {
        _ = posix.system.close(self.master);
        _ = posix.system.close(self.slave);
        self.* = undefined;
    }
};

test "Pty open and exec" {
    const testing = std.testing;
    const size = winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    var pty_instance = try Pty.open(size);
    defer pty_instance.deinit();

    // Test PTY creation
    try testing.expect(pty_instance.master >= 0);
    try testing.expect(pty_instance.slave >= 0);

    // Test exec (fork and execute shell)
    const pid = try posix.fork();
    _ = try pty_instance.exec(pid);
    try testing.expect(pid > 0);
    try testing.expectEqual(pid, pty_instance.pid);

    // Test writing to PTY
    const input = "echo Hello\n";
    const written = try pty_instance.write(input);
    try testing.expectEqual(input.len, written);

    // Test reading from PTY (may require polling due to non-blocking mode)
    var buf: [128]u8 = undefined;
    var total_read: usize = 0;
    while (total_read == 0) {
        total_read = pty_instance.read(buf[0..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        std.time.sleep(10 * std.time.ns_per_ms); // Wait briefly
    }
    try testing.expect(std.mem.containsAtLeast(u8, buf[0..total_read], 1, "Hello"));

    // Clean up child process
    // try posix.kill(pid, posix.SIG.TERM);
    try pty_instance.killit();
    // try pty_instance.ttyhangup();
}

pub fn main() !void {
    if (comptime util.isDebug) {
        var alloc = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = alloc.deinit();
        const allocator = alloc.allocator();

        // _ = c.XSetLocaleModifiers("");

        //bench TODO:make another folder with benches

        // const s1 = "hello world";
        // const s2 = "hello world";
        // const s3 = "hello worlD";

        // // Medium buffer
        // const med_size = 10_000;
        // const med1 = try createTestBuffer(allocator, med_size, 'A');
        // defer allocator.free(med1);
        // const med2 = try createTestBuffer(allocator, med_size, 'A');
        // defer allocator.free(med2);
        // const med3 = try createTestBuffer(allocator, med_size, 'B');
        // defer allocator.free(med3);

        // // Large buffer
        // const large_size = 1_000_000;
        // const large1 = try createTestBuffer(allocator, large_size, 'X');
        // defer allocator.free(large1);
        // const large2 = try createTestBuffer(allocator, large_size, 'X');
        // defer allocator.free(large2);
        // const large3 = try createTestBuffer(allocator, large_size, 'Y');
        // defer allocator.free(large3);

        // print("\n=== Small strings (12 bytes) ===\n", .{});
        // try runBenchmark("Identical", s1, s2);
        // try runBenchmark("Different last char", s1, s3);

        // print("\n=== Medium buffers (10,000 bytes) ===\n", .{});
        // try runBenchmark("Identical", med1, med2);
        // try runBenchmark("Different middle", med1, med3);

        // print("\n=== Large buffers (1,000,000 bytes) ===\n", .{});
        // try runBenchmark("Identical", large1, large2);
        // try runBenchmark("Completely different", large1, large3);

        _ = c.setlocale(c.LC_CTYPE, "");
        var term = try xlib.XlibTerminal.init(allocator);
        defer term.deinit();
        try term.run();
    } else {
        // const allocator = std.heap.c_allocator;

        var smp = std.heap.SmpAllocator{
            .cpu_count = 1,
            .threads = @splat(.{}),
        };
        const allocator = std.mem.Allocator{
            .ptr = &smp,
            .vtable = &std.heap.SmpAllocator.vtable,
        };
        _ = c.setlocale(c.LC_CTYPE, "");
        // _ = c.XSetLocaleModifiers("");

        var term = try xlib.XlibTerminal.init(allocator);
        defer term.deinit();

        // term.testing();
        try term.run();
    }
}

fn createTestBuffer(allocator: std.mem.Allocator, size: usize, fill: u8) ![]u8 {
    const buf = try allocator.alloc(u8, size);
    @memset(buf, fill);
    return buf;
}

fn wrap_eql(a: []const u8, b: []const u8) bool {
    return util.eql(u8, a, b);
}

fn wrap_default(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn wrap_compare(a: []const u8, b: []const u8) bool {
    return util.compare(a, b);
}

fn runBenchmark(comptime label: []const u8, a: []const u8, b: []const u8) !void {
    const iterations = 100_000;

    const eql_time = try measure(iterations, wrap_eql, a, b);
    const std_time = try measure(iterations, wrap_default, a, b);

    const compare_time = try measure(iterations, wrap_compare, a, b);

    print(
        \\{s}:
        \\  eql:     {d:>5} ns/op ({d:>5.1} MB/s)
        \\  std:     {d:>5} ns/op ({d:>5.1} MB/s)
        \\  compare: {d:>5} ns/op ({d:>5.1} MB/s)
        \\
    , .{
        label,
        eql_time,
        throughput(a.len, eql_time),
        std_time,
        throughput(a.len, std_time),
        compare_time,
        throughput(a.len, compare_time),
    });
}

fn throughput(bytes: usize, ns_per_op: u64) f64 {
    const bytes_per_sec = @as(f64, 1e9 / @as(f64, @floatFromInt(ns_per_op))) * @as(f64, @floatFromInt(bytes));
    return bytes_per_sec / (1024 * 1024);
}

fn measure(
    iterations: usize,
    comptime func: fn ([]const u8, []const u8) bool,
    a: []const u8,
    b: []const u8,
) !u64 {
    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Prevent compiler optimization
        std.mem.doNotOptimizeAway(func(a, b));
    }

    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
    return elapsed / iterations;
}
