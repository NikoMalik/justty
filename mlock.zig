const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const log = std.log;

const MemoryLockError = error{memory_not_locked} || std.posix.UnexpectedError;

const mlockall_error = "Unable to lock pages in memory ({s})" ++
    " - kernel swap would otherwise bypass TigerBeetle's storage fault tolerance. ";

/// Pin virtual memory pages allocated so far to physical pages in RAM, preventing the pages from
/// being swapped out and introducing storage error into memory, bypassing ECC RAM.
pub fn memory_lock_allocated() MemoryLockError!void {
    switch (builtin.os.tag) {
        .linux => try memory_lock_allocated_linux(),
        .macos => {},
        else => @compileError("unsupported platform"),
    }
}

pub fn unexpected_errno(label: []const u8, err: std.posix.system.E) std.posix.UnexpectedError {
    log.scoped(.stdx).err("unexpected errno: {s}: code={d} name={?s}", .{
        label,
        @intFromEnum(err),
        std.enums.tagName(std.posix.system.E, err),
    });

    if (builtin.mode == .Debug) {
        std.debug.dumpCurrentStackTrace(null);
    }
    return error.Unexpected;
}

fn memory_lock_allocated_linux() MemoryLockError!void {
    const MCL_CURRENT = 1; // Lock all currently mapped pages.
    const MCL_ONFAULT = 4; // Lock all pages faulted in (i.e. stack space).
    const result = os.linux.syscall1(.mlockall, MCL_CURRENT | MCL_ONFAULT);
    switch (os.linux.E.init(result)) {
        .SUCCESS => return,
        .AGAIN => log.warn(mlockall_error, .{"some addresses could not be locked"}),
        .NOMEM => log.warn(mlockall_error, .{"memory would exceed RLIMIT_MEMLOCK"}),
        .PERM => log.warn(mlockall_error, .{
            "insufficient privileges to lock memory",
        }),
        .INVAL => unreachable, // MCL_ONFAULT specified without MCL_CURRENT.
        else => |err| return unexpected_errno("mlockall", err),
    }
    return error.memory_not_locked;
}
