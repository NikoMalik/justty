const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const linux = std.os.linux;
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

// pub extern "c" fn mkstemp(template: ?[*:0]const u8) c_int;
// pub extern "c" fn mkostemp(template: ?[*:0]const u8, flags: c_int) c_int;

// POSIX shared memory (POSIX shm)

pub inline fn strideForFormatAndWidth(format: c.pixman_format_code_t, width: u16) !u16 {
    const bpp = c.PIXMAN_FORMAT_BPP(format);
    const bytes = (bpp * @as(u32, width) + 7) / 8;
    const aligned = (bytes + 3) & ~@as(u32, 3);
    if (aligned > std.math.maxInt(u16)) {
        return error.StrideOverflow;
    }
    return @intCast(aligned);
}
const Container = struct {
    drawable: c.xcb_drawable_t,
    width: u16,
    height: u16,
};

const Buf = struct {
    id: posix.fd_t,
    allocator: Allocator,
    conn: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    gc: c.xcb_gcontext_t,
    container: Container,
    x: f32,
    y: f32,
    width: u16,
    height: u16,
    px: [*]u32,
    pixman_image: *c.pixman_image_t,
    mapped: *anyopaque,

    is_shm: bool,
    shm: sh,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        conn: *c.xcb_connection_t,
        screen: *c.xcb_screen_t,
        container: c.xcb_drawable_t,
        w: u16,
        h: u16,
    ) !Self {
        const gc = c.xcb_generate_id(conn);
        const stride = strideForFormatAndWidth(c.PIXMAN_x8r8g8b8, w);
        const size = stride * h;

        _ = c.xcb_create_gc(conn, gc, container, 0, null);
        var is_shm = false;
        var shm_seg: c.xcb_shm_seg_t = 0;
        var pixmap: c.xcb_pixmap_t = 0;
        if (is_shm_available(conn)) {
            is_shm = true;
            shm_seg = c.xcb_generate_id(conn);
            pixmap = c.xcb_generate_id(conn);

            var pool_fd = c.memfd_create(
                "justty-shm",
                c.MFD_CLOEXEC | c.MFD_ALLOW_SEALING | c.MFD_NOEXEC_SEAL,
            );

            if (pool_fd < 0) {
                pool_fd = c.memfd_create(
                    "justty-shm",
                    c.MFD_CLOEXEC | c.MFD_ALLOW_SEALING,
                );
            }
            // const pool_fd = posix.memfd_create("justty-shm",  linux.MFD.ALLOW_SEALING | linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING );
            if (linux.ftruncate(@intCast(pool_fd), @intCast(size)) < 0) {
                std.log.err("Failed to set SHM size: {}", .{std.c._errno(pool_fd)});
                return error.ShmTruncateFailed;
            }
            errdefer posix.close(pool_fd);
            const mmapped = posix.mmap(
                null,
                size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED, .UNINITIALIZED = true },
                pool_fd,
                0,
            ) catch |err| {
                std.log.err("Failed to mmap SHM: {}", .{err});
                return error.MmapFailed;
            };
            errdefer if (mmapped != null) posix.munmap(mmapped);
            //seal shm memory
            _ = try posix.fcntl(
                pool_fd,
                posix.F.ADD_SEALS,
                posix.F.SEAL_GROW | posix.F.SEAL_SHRINK | posix.F.SEAL_SEAL,
            );

            _ = c.xcb_shm_attach_fd(conn, shm_seg, @intCast(pool_fd), 0);
            _ = c.xcb_shm_create_pixmap(
                conn,
                pixmap,
                container,
                w,
                h,
                screen.*.root_depth,
                shm_seg,
                0,
            );
            const pix = c.pixman_image_create_bits_no_clear(
                c.PIXMAN_a8r8g8b8,
                @intCast(w),
                @intCast(h),
                @ptrCast(mmapped),
                @intCast(stride),
            );
            errdefer c.pixman_image_unref(pix);
            if (pix == null) {
                std.log.err("Failed to create pixman image", .{});
                return error.PixmanImageCreateFailed;
            }

            return Self{
                .conn = conn,
                .screen = screen,
                .allocator = allocator,
                .gc = gc,
                .container = Container{ .drawable = container, .width = w, .height = h },
                .x = 0.0,
                .y = 0.0,
                .width = w,
                .height = h,
                .px = @ptrCast(mmapped.?),
                .pixman_image = pix,
                .mapped = mmapped.?,
                .is_shm = true,
                .shm = sh.base{
                    .seg = shm_seg,
                    .pixmap = pixmap,
                },
                // .image = image,
                .stride = stride,
                .size = size,
            };
        } else {
            is_shm = false;
            pixmap = c.xcb_generate_id(conn);

            errdefer _ = c.xcb_free_pixmap(conn, pixmap);

            _ = c.xcb_create_pixmap(
                conn,
                screen.*.root_depth,
                pixmap,
                container,
                w,
                h,
            );

            const data = try allocator.alignedAlloc(u32, 4, size);
            errdefer allocator.free(data);

            const pix = c.pixman_image_create_bits_no_clear(
                c.PIXMAN_a8r8g8b8,
                @intCast(w),
                @intCast(h),
                @ptrCast(data.ptr),
                @intCast(stride),
            ) orelse return error.PixmanImageCreateFailed;
            errdefer c.pixman_image_unref(pix);
            const image = c.xcb_image_create_native(
                conn,
                w,
                h,
                c.XCB_IMAGE_FORMAT_Z_PIXMAP,
                screen.*.root_depth,
                @ptrCast(data.ptr),
                @intCast(size),
                @ptrCast(data.ptr),
            );
            return Self{
                .allocator = allocator,
                .conn = conn,
                .screen = screen,
                .gc = gc,
                .container = Container{ .drawable = container, .width = w, .height = h },
                .x = 0.0,
                .y = 0.0,
                .width = w,
                .height = h,
                .px = @ptrCast(data.ptr),
                .pixman_image = pix,
                .mapped = data,
                .is_shm = false,
                .shm = .{ .no_base = .{ .image = image } },
                .stride = stride,
                .size = size,
            };
        }
    }

    pub fn deinit(self: *Self) void {
        c.pixman_image_unref(self.pixman_image);
        if (self.is_shm) {
            posix.munmap(self.mapped.ptr, self.size) catch {};
            _ = c.xcb_shm_detach(self.conn, self.shm.shm.seg);
            _ = c.xcb_free_pixmap(self.conn, self.shm.shm.pixmap);
            posix.close(self.shm.shm.id);
        } else {
            self.allocator.free(self.mapped);
            c.xcb_image_destroy(self.shm.no_base.image);
        }
        _ = c.xcb_free_gc(self.conn, self.gc);
    }

    pub fn is_shm_available(conn: *c.xcb_connection_t) bool {
        const cookie = c.xcb_shm_query_version(conn);
        const e = c.xcb_request_check(conn, cookie);
        if (e != null) {
            std.log.err("ERROR: {}", .{e.*.error_code});
            c.xcb_disconnect(conn);
            std.process.exit(1);
        }
        const reply = c.xcb_shm_query_version_reply(
            conn,
            cookie,
            e,
        );
        defer std.c.free(e);
        defer std.c.free(reply);
        if (reply == null or reply.*.shared_pixmaps == 0) {
            return false;
        }
        return true;
    }
};

const sh = union {
    base: struct {
        seg: c.xcb_shm_seg_t,
        pixmap: c.xcb_pixmap_t,
    },
    no_base: struct {
        image: *c.xcb_image_t,
    },
};
