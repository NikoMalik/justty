const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const linux = std.os.linux;
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const builtin = @import("builtin");

pub inline fn strideForFormatAndWidth(
    format: c.pixman_format_code_t,
    width: u16,
) !u16 {
    const bpp = c.PIXMAN_FORMAT_BPP(format);
    const bytes = (bpp * @as(u32, width) + 7) / 8;
    const aligned = (bytes + 3) & ~@as(u32, 3);
    if (aligned > std.math.maxInt(u16)) {
        return error.StrideOverflow;
    }
    return @intCast(aligned);
}

pub inline fn create_shm_file(size: usize) !?usize {
    if (try shm_open_anon()) |fd| {
        if (linux.ftruncate(fd, @intCast(size)) < 0) {
            std.posix.close(fd);
            return null;
        } else {
            return @intCast(fd);
        }
    }
    return null;
}

pub inline fn shm_open_anon() !?i32 {
    var name: [30:0]u8 = undefined;
    name[0] = '/';
    var ts: std.c.timespec = undefined;
    std.c.clock_get_time(std.c.CLOCK.REALTIME, &ts);
    var r = std.Random.DefaultPrng.init(@intCast(ts.nsec));
    var i: usize = 0;
    return while (i < 100) : (i += 1) {
        r.random().bytes(name[1..]);
        const fd = std.c.shm_open(
            &name,

            @as(c_int, @bitCast(std.c.O{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .EXCL = true,
            })),
            0o600,
        );
        if (fd < 0) {
            switch (std.posix.errno(fd)) {
                .ACCES => error.PermissionDenied,
                .EXIST => error.ObjectFileAlreadyExists,

                else => |err| {
                    std.log.warn("unable to open shared memory : {}", .{err});
                    return error.InvalidData;
                },
            }
        }
        if (fd >= 0) {
            _ = std.c.shm_unlink(&name);
            break fd;
        }
    } else null;
}

const Container = struct {
    drawable: c.xcb_drawable_t,
    width: u16,
    height: u16,
};

pub const Buf = struct {
    allocator: Allocator,
    conn: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    gc: c.xcb_gcontext_t,
    container: Container,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    size: usize,
    // px: [*]u32,
    pixman_image: *c.pixman_image_t,
    // mapped: *anyopaque,
    mapped: []align(std.heap.page_size_min) u8,
    deinit_bool: bool,
    is_shm: bool,
    shm: sh,

    const Self = @This();

    const MFD_NOEXEC_SEAL: u32 = if (@hasDecl(linux.MFD, "NOEXEC_SEAL"))
        linux.MFD.NOEXEC_SEAL
    else
        0x0000;
    const F_ADD_SEALS = if (@hasDecl(posix.F, "ADD_SEALS"))
        posix.F.ADD_SEALS
    else
        1025;
    const F_SEAL_GROW = if (@hasDecl(posix.F, "SEAL_GROW"))
        posix.F.SEAL_GROW
    else
        0x0004;
    const F_SEAL_SHRINK = if (@hasDecl(posix.F, "SEAL_SHRINK"))
        posix.F.SEAL_SHRINK
    else
        0x0002;
    const F_SEAL_SEAL = if (@hasDecl(posix.F, "SEAL_SEAL"))
        posix.F.SEAL_SEAL
    else
        0x0008;

    pub fn init(
        allocator: Allocator,
        conn: *c.xcb_connection_t,
        screen: *c.xcb_screen_t,
        container: c.xcb_drawable_t,
        w: u16,
        h: u16,
    ) !Self {
        const gc = c.xcb_generate_id(conn);
        const stride = try strideForFormatAndWidth(c.PIXMAN_a8r8g8b8, w);
        const size: usize = try countSize(
            stride,
            h,
        );
        _ = c.xcb_create_gc(conn, gc, container, 0, null);
        var is_shm = false;
        var shm_seg: c.xcb_shm_seg_t = 0;
        var pixmap: c.xcb_pixmap_t = 0;
        if (comptime build_options.shm) {
            is_shm = true;
            shm_seg = c.xcb_generate_id(conn);
            pixmap = c.xcb_generate_id(conn);

            const flags = linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING |
                MFD_NOEXEC_SEAL;

            var pool_fd: usize = undefined;
            if (comptime build_options.memfd) {
                pool_fd = linux.memfd_create(
                    "justty-shm",
                    flags,
                );

                if (pool_fd < 0) {
                    pool_fd = linux.memfd_create(
                        "justty-shm",
                        posix.MFD.CLOEXEC | posix.MFD.ALLOW_SEALING,
                    );
                }
            } else {
                pool_fd = try create_shm_file(size);
            }

            if (linux.ftruncate(@intCast(pool_fd), @intCast(size)) < 0) {
                std.log.err("Failed to set SHM size: {}", .{std.c._errno(pool_fd)});
                return error.ShmTruncateFailed;
            }
            errdefer _ = linux.close(@intCast(pool_fd));
            const mmapped = posix.mmap(
                null,
                size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED, .UNINITIALIZED = true },
                @intCast(pool_fd),
                0,
            ) catch |err| {
                std.log.err("Failed to mmap SHM: {}", .{err});
                return error.MmapFailed;
            };
            if (comptime build_options.memfd) {
                _ = posix.fcntl( // seal memfd fd memory
                    @intCast(pool_fd),
                    F_ADD_SEALS,
                    F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL,
                ) catch |err| {
                    std.log.warn("Failed to seal SHM: {}", .{err});
                };
            }

            errdefer posix.munmap(mmapped);
            _ = c.xcb_shm_attach_fd(conn, shm_seg, @intCast(pool_fd), 0);
            _ = c.xcb_shm_create_pixmap(
                conn,
                pixmap,
                container,
                w,
                h,
                32,
                shm_seg,
                0,
            );
            const pix = c.pixman_image_create_bits_no_clear(
                c.PIXMAN_a8r8g8b8,
                @intCast(w),
                @intCast(h),
                @ptrCast(mmapped.ptr),
                @intCast(stride),
            );
            errdefer _ = c.pixman_image_unref(pix);
            if (pix == null) {
                std.log.err("Failed to create pixman image", .{});
                return error.PixmanImageCreateFailed;
            }

            std.log.info("complete init buffer", .{});

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
                .pixman_image = pix.?,
                .mapped = mmapped, // []align(4096) u8
                .is_shm = true,
                .deinit_bool = false,
                .shm = .{
                    .base = .{
                        .id = @intCast(pool_fd),
                        .seg = shm_seg,
                        .pixmap = pixmap,
                    },
                },
                // .image = image,
                // .stride = stride,
                .size = size,
            };
        } else {
            is_shm = false;
            std.log.info("used buf wihtout shm backend", .{});
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

            const data = try allocator.alignedAlloc(u8, std.heap.page_size_min, size);
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
                .deinit_bool = false,
                .width = w,
                .height = h,
                // .px = @ptrCast(data.ptr),
                .pixman_image = pix,
                .mapped = data,
                .is_shm = false,
                .shm = .{ .no_base = .{ .image = image } },
                // .stride = stride,
                .size = size,
            };
        }
    }

    pub fn draw(self: *Self) !void {
        const cont_w = self.container.width;
        const cont_h = self.container.height;

        // Clear top
        if (self.y > 0) {
            _ = c.xcb_clear_area(
                self.conn,
                0,
                self.container.drawable,
                0,
                0,
                cont_w,
                @intCast(self.y),
            );
        }

        // CLear reft side
        if (self.x > 0) {
            _ = c.xcb_clear_area(
                self.conn,
                0,
                self.container.drawable,
                0,
                0,
                @intCast(self.x),
                cont_h,
            );
        }

        // Clear bottom
        if (@as(u16, @intCast(self.y)) + self.height < cont_h) {
            _ = c.xcb_clear_area(
                self.conn,
                0,
                self.container.drawable,
                0,
                self.y + @as(i16, @intCast(self.height)),
                cont_w,
                cont_h - (@as(u16, @intCast(self.y)) + self.height),
            );
        }

        // Clear RIght side
        if (@as(u16, @intCast(self.x)) + self.width < cont_w) {
            _ = c.xcb_clear_area(
                self.conn,
                0,
                self.container.drawable,
                self.x + @as(i16, @intCast(self.width)),
                0,
                cont_w - @as(u16, @intCast(self.x)) + self.width,
                cont_h,
            );
        }

        if (self.is_shm) {
            _ = c.xcb_copy_area(
                self.conn,
                self.shm.base.pixmap,
                self.container.drawable,
                self.gc,
                0,
                0,
                self.x,
                self.y,
                0,
                0,
            );
        } else {
            _ = c.xcb_image_put(
                self.conn,
                self.container.drawable,
                self.gc,
                self.shm.no_base.image,
                self.x,
                self.y,
                0,
            );
        }
        _ = c.xcb_flush(self.conn);
    }

    pub fn deinit(self: *Self) void {
        if (self.deinit_bool) {
            return;
        }
        self.deinit_bool = true;
        _ = c.pixman_image_unref(self.pixman_image);
        if (self.is_shm) {
            posix.munmap(self.mapped);
            _ = c.xcb_shm_detach(self.conn, self.shm.base.seg);
            _ = c.xcb_free_pixmap(self.conn, self.shm.base.pixmap);
            posix.close(self.shm.base.id);
        } else {
            self.allocator.free(self.mapped);
            c.xcb_image_destroy(self.shm.no_base.image);
        }
        _ = c.xcb_free_gc(self.conn, self.gc);
    }

    pub fn rect(self: *Self, x: i16, y: i16, w: i16, h: i16, color: u32) void {
        var dx: i16 = 0;
        var dy: i16 = 0;

        var rect_x = x;
        var rect_y = y;
        var rect_w = w;
        var rect_h = h;

        if (rect_x < 0) {
            rect_w += rect_x;
            rect_x = 0;
        }
        if (rect_y < 0) {
            rect_h += rect_y;
            rect_y = 0;
        }
        if (rect_x + rect_w > self.width) {
            rect_w = @intCast(self.width - @as(u16, @intCast(rect_x)));
        }
        if (rect_y + rect_h > self.height) {
            rect_h = @intCast(self.height - @as(u16, @intCast(rect_y)));
        }

        if (rect_w <= 0 or rect_h <= 0) return;

        const pixels: [*]u32 = @ptrCast(@alignCast(self.mapped.ptr));
        while (dy < rect_h) : (dy += 1) {
            dx = 0;
            while (dx < rect_w) : (dx += 1) {
                const px_idx = (@as(usize, @intCast(rect_y + dy)) * @as(usize, self.width)) + @as(usize, @intCast(rect_x + dx));
                pixels[px_idx] = color;
            }
        }
    }

    pub fn clear(self: *Self, color: u32) void {
        const pixels: [*]u32 = @ptrCast(@alignCast(self.mapped.ptr));
        const total_pixels = @as(usize, self.width) * @as(usize, self.height);
        @memset(pixels[0..total_pixels], color);
    }
    pub fn setContainerSize(self: *Self, cw: u16, ch: u16) void {
        const dx: i32 = @divFloor(@as(i32, cw) - @as(i32, self.container.width), 2);
        const dy: i32 = @divFloor(@as(i32, ch) - @as(i32, self.container.height), 2);
        std.log.debug("Updating container size: cw={d}, ch={d}, dx={d}, dy={d}, new_x={d}, new_y={d}", .{ cw, ch, dx, dy, self.x + dx, self.y + dy });
        self.x += @intCast(dx);
        self.y += @intCast(dy);
        self.container.width = cw;
        self.container.height = ch;
    }
    fn is_shm_available(conn: *c.xcb_connection_t) bool {
        const cookie = c.xcb_shm_query_version(conn);
        const reply = c.xcb_shm_query_version_reply(conn, cookie, null);
        defer if (reply != null) std.c.free(reply);
        return reply != null and reply.*.shared_pixmaps != 0;
    }
};

inline fn countSize(stride: u16, h: u16) !usize {
    return try std.math.mul(u32, @intCast(stride), @intCast(h));
}

const sh = union {
    base: struct {
        id: posix.fd_t,
        seg: c.xcb_shm_seg_t,
        pixmap: c.xcb_pixmap_t,
    },
    no_base: struct {
        image: *c.xcb_image_t,
    },
};
