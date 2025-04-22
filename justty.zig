const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const builtin = @import("builtin");
const log = std.log;
const xlib = @import("x.zig");
const util = @import("util.zig");

test {
    std.testing.refAllDecls(@This());
}
const TIOCSCTTY = c.TIOCSCTTY;
const TIOCSWINSZ = c.TIOCSWINSZ;
const TIOCGWINSZ = c.TIOCGWINSZ;

pub const winsize = c.winsize;

//=========================//* utf consts //=======================
const UTF_INVALID = 0xFFFD;
const ESC_BUF_SIZ = 128 * UTF_SIZ;
const UTF_SIZ = 4;

const ESC_ARG_SIZ = 16;
const STR_BUF_SIZ = ESC_BUF_SIZ;
const STR_ARG_SIZ = ESC_ARG_SIZ;

//=========================//* utf consts //=======================
//
//

const Term = struct {
    row: u16, // nb row
    col: u16, // nb col
    tw: u16, // xpixel
    th: u16, // ypixel

};

const term_mode = union(enum(u8)) {
    MODE_WRAP = 1 << 0,
    MODE_INSERT = 1 << 1,
    MODE_ALTSCREEN = 1 << 2,
    MODE_CRLF = 1 << 3,
    MODE_ECHO = 1 << 4,
    MODE_PRINT = 1 << 5,
    MODE_UTF8 = 1 << 6,
};

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

    pub fn exec(self: *Self, pid: posix.pid_t) !void {
        const shell = getShellPath();
        if (pid != 0) {
            // log.warn("fork failed: {}", .{});
            posix.close(self.slave);
        }
        if (pid == 0) {
            const sid = setsid();
            if (sid == -1) {
                return error.SetSid_failed;
            }
            const ff = c.ioctl(self.slave, c.TIOCSCTTY, @as(c_int, 0));
            if (ff == -1) return error.IdkIoctl_exec;
            try posix.dup2(self.slave, posix.STDIN_FILENO);
            try posix.dup2(self.slave, posix.STDOUT_FILENO);
            try posix.dup2(self.slave, posix.STDERR_FILENO);
            posix.close(self.slave);
            // const e = posix.execvpeZ("/bin/echo", &[_:null]?[*:0]const u8{ "sh", null, null }, std.c.environ);
            const e = std.posix.execvpeZ(shell, &.{ shell, null }, std.c.environ);
            std.debug.print("could not exec shell: {}\n", .{e});
            std.c.exit(1);
        }
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

pub fn main() !void {
    if (comptime util.isDebug) {
        var alloc = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
        defer _ = alloc.deinit();
        const allocator = alloc.allocator();
        _ = c.setlocale(c.LC_CTYPE, "");
        // _ = c.XSetLocaleModifiers("");
        std.debug.print("hello ", .{});
        std.debug.print("font : {s}\n", .{c.font});

        var term = try xlib.XlibTerminal.init(allocator);
        defer term.deinit();
        try term.run();
    } else {
        const allocator = std.heap.c_allocator;
        _ = c.setlocale(c.LC_CTYPE, "");
        // _ = c.XSetLocaleModifiers("");

        var term = try xlib.XlibTerminal.init(allocator);
        defer term.deinit();
        try term.run();
    }
}
