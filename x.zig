const std = @import("std");
const c = @import("c.zig");
const justty = @import("justty.zig");
const posix = std.posix;
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

const colorname_len = c.COLORNAME_LEN;

// Purely graphic info //
const TermWindow = packed struct {
    // tty width and height */
    tw: usize,
    th: usize,
    // window width and height */
    w: usize,
    h: usize,
    // char height */
    ch: usize,
    // char width  */
    cw: usize,
    // cursor style */
    cursor: usize,
    // window state/mode flags */
    mode: u8,
};

//* Font structure */
const Font = struct {
    height: usize,
    width: usize,
    ascent: usize,
    badslant: usize,
    lbearing: u16,
    rbearing: u16,
    match: *c.XftFont,
    set: *c.FcFontSet,
    pattern: *c.FcPattern,
};

// Drawing Context
const DC = struct {
    col: []c.XftColor, // colors,TODO:try with array
    collen: usize,
    gc: c.GC,
    font: Font,
};

pub const XlibTerminal = struct {
    display: *c.Display,
    screen: i32,
    window: c.Window,
    font: *c.XftFont,
    colormap: c.Colormap,
    allocator: Allocator,
    pty: justty.Pty,
    pid: posix.pid_t,
    vis: *c.Visual,
    dc: DC,
    output: [1024]u8 = undefined, // Buffer to store pty output
    win: TermWindow,
    attrs: c.XSetWindowAttributes,
    output_len: usize = 0, // Length of stored output
    left: c_int = 0,
    right: c_int = 0,
    gm: c_int,

    const Self = @This();

    pub fn init(gm: c_int, allocator: Allocator) !Self {
        const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        errdefer _ = c.XCloseDisplay(display);

        const screen = c.XDefaultScreen(display);
        const root = c.XRootWindow(display, screen);
        const visual = c.XDefaultVisual(display, screen);

        // const window = c.XCreateSimpleWindow(
        //     display,
        //     root,
        //     0,
        //     0,
        //     800,
        //     600,
        //     1,
        //     c.XWhitePixel(display, screen),
        //     c.XBlackPixel(display, screen),
        // );
        //
        //font
        if (!(c.FcInit())) {
            return error.Fcinit_errror_created;
        }
        //load fonts
        const _font_ = c.XftFontOpenName(display, screen, c.font) orelse return error.CannotLoadFont;
        errdefer _ = c.XftFontClose(display, _font_);
        //load fonts function

        // colormap
        //
        //
        const cmap = c.XDefaultColormap(display, screen);
        //load colors
        //
        //adjust fixed window geometry //
        var win: TermWindow = undefined;
        win.w = 2 * c.borderpx + c.cols * win.cw;
        win.h = 2 * c.borderpx + c.rows * win.ch;

        var l: c_int = 0;
        var t: c_int = 0;

        if (gm & c.XNegative) {
            l = c.DisplayWidth(display, screen) - win.w - 2;
        }
        if (gm & c.YNegative) {
            t = c.DisplayHeight(display, screen) - win.h - 2;
        }

        //============drawing_context======================//
        var dc: DC = undefined;
        dc.collen = allocator.alloc(c.XftColor, @max(colorname_len, 256)); //alloc

        // ================================================//

        //attrs
        var attrs: c.XSetWindowAttributes = undefined;
        attrs.background_pixel = dc.col[c.defaultbg].pixel;
        attrs.border_pixel = dc.col[c.defaultbg].pixel;
        attrs.bit_gravity = c.NorthWestGravity;

        attrs.event_mask = c.FocusChangeMask | c.KeyPressMask | c.KeyReleaseMask | c.ExposureMask | c.VisibilityChangeMask | c.StructureNotifyMask | c.ButtonMotionMask | c.ButtonPressMask | c.ButtonReleaseMask;
        attrs.colormap = cmap;

        const window = c.XCreateWindow(
            display,
            root,
            l,
            t,
            @as(c_uint, @intCast(win.w)),
            @as(c_uint, @intCast(win.h)),
            0,
            c.XDefaultDepth(display, screen),
            c.InputOutput,
            visual,
            c.CWBackPixel | c.CWBorderPixel | c.CWBitGravity | c.CWEventMask | c.CWColormap,
            @intFromPtr(&attrs),
        );
        if (window == 0) return error.CannotCreateWindow;
        errdefer _ = c.XDestroyWindow(display, window);

        _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);
        _ = c.XMapWindow(display, window);

        const initial_size: justty.winsize = .{ .ws_row = c.rows, .ws_col = c.cols, .ws_xpixel = 0, .ws_ypixel = 0 };
        var pty = try justty.Pty.open(initial_size);
        errdefer pty.deinit();

        const pid = try posix.fork();
        try pty.exec(pid);

        return .{
            .display = display,
            .screen = screen,
            .window = window,
            .font = _font_,
            .pty = pty,
            .pid = pid,
            .vis = visual,
            .colormap = cmap,
            .left = l,
            .right = t,
            .win = win,
            .dc = dc,
            .allocator = allocator,
        };
    }

    // pub fn run(self: *Self) !void {
    //     var event: c.XEvent = undefined;
    //     var buffer: [1024]u8 = undefined;

    //     // Read all output from pty until EOF (child process exits)
    //     while (true) {
    //         // const n = posix.read(self.pty.master, &buffer) catch 0;
    //         const n = posix.read(self.pty.master, &buffer) catch 0;
    //         if (n == 0) break; // EOF reached

    //         if (n > 0) {
    //             const end = @min(self.output_len + n, self.output.len);
    //             util.copy(u8, self.output[self.output_len..end], buffer[0..n]);
    //             self.output_len = end;

    //             self.redraw();
    //         }
    //         // util.copy(u8, self.output[self.output_len..], buffer[0..n]);
    //         // self.output_len += n;
    //     }

    //     // Event loop to handle X11 events
    //     while (c.XPending(self.display) > 0) {
    //         _ = c.XNextEvent(self.display, &event);
    //         self.handleEvent(&event);
    //     }
    // }

    pub fn run(self: *Self) !void {
        // Get the X11 connection file descriptor
        const xfd = c.XConnectionNumber(self.display);

        // Set up pollfd array for X11 and pty master
        var fds: [2]std.posix.pollfd = .{
            .{ .fd = xfd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.pty.master, .events = std.posix.POLL.IN, .revents = 0 },
        };

        var buffer: [1024]u8 = undefined;

        // Main loop
        while (true) {
            // Wait for events on either fd (-1 means no timeout)
            _ = std.posix.poll(&fds, -1) catch |err| {
                std.log.err("poll error: {}", .{err});
                return err;
            };

            // Check for X11 events
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                while (c.XPending(self.display) > 0) {
                    var event: c.XEvent = undefined;
                    _ = c.XNextEvent(self.display, &event);
                    self.handleEvent(&event);
                }
            }

            // Check for pty output
            if (fds[1].revents & std.posix.POLL.IN != 0) {
                const n = posix.read(self.pty.master, &buffer) catch |err| {
                    std.log.err("read error from pty: {}", .{err});
                    continue;
                };
                if (n > 0) {
                    if (comptime util.allow_assert) {
                        //  Debug output to verify data is read
                        std.debug.print("Read {} bytes: {s}\n", .{ n, buffer[0..n] });
                    }

                    // Append to output buffer
                    const end = @min(self.output_len + n, self.output.len);
                    util.copy(u8, self.output[self.output_len..end], buffer[0..n]);
                    self.output_len = end;
                    self.redraw();
                } else if (n == 0) {
                    if (comptime util.allow_assert) {
                        std.debug.print("Shell exited\n", .{});
                    }
                    // EOF: Child process exited
                    break;
                }
            }
        }
    }

    fn handleEvent(self: *Self, event: *c.XEvent) void {
        switch (event.type) {
            c.Expose => self.redraw(),
            c.KeyPress => {
                var buf: [32]u8 = undefined;
                const sym = c.XLookupString(&event.xkey, &buf, buf.len, null, null);
                if (sym > 0) {
                    _ = posix.write(self.pty.master, buf[0..@intCast(sym)]) catch {};
                }
            },
            c.ConfigureNotify => {
                const new_size = justty.winsize{
                    .ws_row = @intCast(@divTrunc(event.xconfigure.height, self.font.height)),
                    .ws_col = @intCast(@divTrunc(event.xconfigure.width, self.font.max_advance_width)),

                    .ws_xpixel = 0,
                    .ws_ypixel = 0,
                };
                self.pty.resize(new_size) catch {};
            },
            else => {},
        }
    }

    fn redraw(self: *Self) void {
        const draw = c.XftDrawCreate(
            self.display,
            self.window,
            self.vis,
            // c.XDefaultVisual(
            //     self.display,
            //     self.screen,
            // ),
            // c.XDefaultColormap(
            //     self.display,
            //     self.screen,
            // ),
            self.colormap,
        );
        defer _ = c.XftDrawDestroy(draw);
        //TODO:cache in col(drawing context)
        var bg_color: c.XftColor = undefined;
        _ = c.XftColorAllocName(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), "black", &bg_color);
        defer c.XftColorFree(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), &bg_color);

        c.XftDrawRect(draw, &bg_color, 0, 0, 800, 600);

        var fg_color: c.XftColor = undefined;
        _ = c.XftColorAllocName(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), "white", &fg_color);
        defer c.XftColorFree(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), &fg_color);

        var y: i32 = self.font.ascent;
        var start: usize = 0;
        while (start < self.output_len) {
            var end = start;
            while (end < self.output_len and self.output[end] != '\n') end += 1;
            c.XftDrawString8(draw, &fg_color, self.font, 10, y, self.output[start..end].ptr, @intCast(end - start));
            y += self.font.height;
            start = end + 1;
        }

        _ = c.XFlush(self.display);
    }

    pub fn deinit(self: *Self) void {
        self.pty.deinit();
        self.allocator.free(self.dc.col);
        _ = c.XftFontClose(self.display, self.font);
        _ = c.XDestroyWindow(self.display, self.window);
        _ = c.XCloseDisplay(self.display);
    }
};
