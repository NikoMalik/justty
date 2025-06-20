const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log;

var is_exiting: bool = false;

pub fn handleSignal(
    comptime T: type,
    terminal: *T,
    signum: c_int,
) callconv(.C) void {
    if (is_exiting) return;
    is_exiting = true;

    log.info("Received signal {}, cleaning up...", .{signum});

    terminal.deinit();

    posix.exit(1);
}

pub fn setupSignalHandlers() !void {
    //  SIGINT and SIGTERM
    const act = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.empty_sigset,
        .flags = 0,
    };

    try posix.sigaction(posix.SIG.INT, &act, null); // Ctrl+C
    try posix.sigaction(posix.SIG.TERM, &act, null); // SIGTERM
    try posix.sigaction(posix.SIG.HUP, &act, null); // SIGHUP
}
