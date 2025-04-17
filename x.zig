const std = @import("std");
const c = @import("c.zig");
const justty = @import("justty.zig");
const posix = std.posix;
const util = @import("util.zig");
const Allocator = std.mem.Allocator;

//TODO:rewrite in xcb

const win_mode = union(enum(u32)) {
    MODE_VISIBLE = 1 << 0,
    MODE_FOCUSED = 1 << 1,
    MODE_APPKEYPAD = 1 << 2,
    MODE_MOUSEBTN = 1 << 3,
    MODE_MOUSEMOTION = 1 << 4,
    MODE_REVERSE = 1 << 5,
    MODE_KBDLOCK = 1 << 6,
    MODE_HIDE = 1 << 7,
    MODE_APPCURSOR = 1 << 8,
    MODE_MOUSESGR = 1 << 9,
    MODE_8BIT = 1 << 10,
    MODE_BLINK = 1 << 11,
    MODE_FBLINK = 1 << 12,
    MODE_FOCUS = 1 << 13,
    MODE_MOUSEX10 = 1 << 14,
    MODE_MOUSEMANY = 1 << 15,
    MODE_BRCKTPASTE = 1 << 16,
    MODE_NUMLOCK = 1 << 17,
    MODE_MOUSE = 1 << 3 | 1 << 4 | 1 << 14 | 1 << 15,
};

// Purely graphic info //
const TermWindow = struct {
    // window state/mode flags */
    mode: win_mode,
    // tty width and height */
    tw: u32,
    th: u32,
    // window width and height */
    w: u32,
    h: u32,
    // char height */
    ch: u32,
    // char width  */
    cw: u32,
    // cursor style */
    cursor: u32,
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
    set: ?*c.FcFontSet,
    pattern: ?*c.FcPattern,
};

// Drawing Context
const DC = struct {
    col: [260]c.XftColor, // colors,TODO:try with array
    // len: usize,
    gc: c.GC,
    font: Font,
};

const ime = struct {
    xim: c.XIM,
    xic: c.XIC,
    spot: c.Xpoint,
    spotlist: c.XVaNestedList,
};

const Atoms = packed struct {
    xembed: c.Atom,
    wmdeletewin: c.Atom,
    netwmname: c.Atom,
    netwmiconname: c.Atom,
    netwmpid: c.Atom,
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
    cursor: c.Cursor,
    xmousebg: c.XColor, //TODO:add in one array in col with bit flags
    xmousefg: c.XColor,
    atoms: Atoms,

    dc: DC,
    draw: *c.XftDraw,
    gc_values: c.XGCValues,
    output: [1024]u8 = undefined, // Buffer to store pty output
    win: TermWindow,
    buf: c.Drawable,
    //==============font spec buffer used for rendering=================//
    specbuf: []c.XftGlyphFontSpec,
    //============================attrs x ===============================//
    attrs: c.XSetWindowAttributes,
    //===================================================================//
    output_len: usize = 0, // Length of stored output
    // left: c_int = 0,
    // top: c_int = 0,
    // gm: c_int,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
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
        if ((c.FcInit() == 0)) {
            return error.Fcinit_errror_created;
        }
        //load fonts
        const _font_ = c.XftFontOpenName(display, screen, c.font) orelse return error.CannotLoadFont;
        const cw = @as(u32, @intCast(_font_.*.max_advance_width));
        const ch = @as(u32, @intCast(_font_.*.height));
        errdefer _ = c.XftFontClose(display, _font_);
        //load fonts function

        // colormap
        //
        //
        const cmap = c.XDefaultColormap(display, screen);
        //load colors
        //adjust fixed window geometry //
        const border_px = @as(u32, @intCast(c.borderpx)); // u32
        const cols_u32 = @as(u32, @intCast(c.cols)); // u8
        const rows_u32 = @as(u32, @intCast(c.rows)); // u8
        var win: TermWindow = .{
            .mode = .MODE_NUMLOCK,
            .tw = cols_u32,
            .th = rows_u32,
            .cw = cw,
            .ch = ch,
            .w = 2 * border_px + cols_u32 * cw,
            .h = 2 * border_px + rows_u32 * ch,
            .cursor = c.mouseshape,
        };

        //============drawing_context======================//
        var dc: DC = undefined;
        // dc.col = try allocator.alloc(c.XftColor, dc.len); //alloc

        dc.font = .{
            .height = @intCast(_font_.*.height),
            .width = @intCast(_font_.*.max_advance_width),
            .ascent = @intCast(_font_.*.ascent),
            .badslant = 0,
            .lbearing = 0,
            .rbearing = 0,
            .match = _font_,
            .set = null,
            .pattern = null,
        };

        for (&dc.col, 0..dc.col.len) |*color, i| {
            if (!xloadcolor(i, null, color, display, visual, cmap)) {
                if (i < c.colorname.len and c.colorname[i] != null) {
                    std.log.err("cannot allocate color name={s}", .{c.colorname[i].?});
                    return error.CannotAllocateColor;
                } else {
                    std.log.err("cannot allocate color {}", .{i});
                    return error.CannotAllocateColor;
                }
            }
        }

        // for (0..dc.col.len) |i| {
        //     var color: c.XftColor = undefined;
        //     const color_name = if (i < c.colorname.len) c.colorname[i] else c.colorname[1];
        //     if (c.XftColorAllocName(display, visual, cmap, color_name, &color) == 0) {
        //         color = .{ .pixel = 0, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0xFFFF } };
        //     }
        //     dc.col[i] = color;
        // }

        // =============================================//

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
            0,
            0,
            @as(c_uint, @intCast(win.w)),
            @as(c_uint, @intCast(win.h)),
            0,
            c.XDefaultDepth(display, screen),
            c.InputOutput,
            visual,
            c.CWBackPixel | c.CWBorderPixel | c.CWBitGravity | c.CWEventMask | c.CWColormap,
            &attrs,
        );
        if (window == 0) return error.CannotCreateWindow;
        errdefer _ = c.XDestroyWindow(display, window);
        //==================gc values=====================//
        var gcvalues: c.XGCValues = undefined;
        @memset(std.mem.asBytes(&gcvalues), 0);
        gcvalues.graphics_exposures = c.False;
        dc.gc = c.XCreateGC(display, window, c.GCGraphicsExposures, &gcvalues);
        errdefer _ = c.XFreeGC(display, dc.gc);
        const buf = c.XCreatePixmap(
            display,
            window,
            @as(c_uint, @intCast(win.w)),
            @as(c_uint, @intCast(win.h)),
            @intCast(c.DefaultDepth(display, @as(c_uint, @intCast(screen)))),
        );

        _ = c.XSetForeground(display, dc.gc, dc.col[c.defaultbg].pixel);
        _ = c.XFillRectangle(
            display,
            buf,
            dc.gc,
            0,
            0,
            @as(c_uint, @intCast(win.w)),
            @as(c_uint, @intCast(win.h)),
        );
        //================spec buf ========================//
        const specbuf = try allocator.alloc(c.XftGlyphFontSpec, c.cols);

        // ================drawable =======================//
        // const draw = c.XftDrawCreate(display, buf, visual, cmap);
        const draw = c.XftDrawCreate(display, buf, visual, cmap) orelse return error.CannotCreateDraw;
        //================= inputs TODO:FINISH INPUT METHODS //
        _ = c.XSelectInput(display, window, c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask);

        const initial_size: justty.winsize = .{ .ws_row = c.rows, .ws_col = c.cols, .ws_xpixel = 0, .ws_ypixel = 0 };

        //========================cursor =================//
        const cursor = c.XCreateFontCursor(display, c.mouseshape);
        _ = c.XDefineCursor(display, window, cursor);
        var xmousefg: c.XColor = undefined;
        var xmousebg: c.XColor = undefined;

        win.cursor = @as(u32, @intCast(cursor));

        if (c.XParseColor(display, cmap, c.colorname[c.mousefg], @intFromPtr(&xmousefg)) == 0) {
            xmousefg.red = 0xffff; // Xcolor
            xmousefg.green = 0xffff;
            xmousefg.blue = 0xffff;
        }

        if (c.XParseColor(display, cmap, c.colorname[c.mousebg], @intFromPtr(&xmousebg)) == 0) {
            xmousebg.red = 0x0000;
            xmousebg.green = 0x0000;
            xmousebg.blue = 0x0000;
        }
        _ = c.XRecolorCursor(display, cursor, @intFromPtr(&xmousefg), @intFromPtr(&xmousebg));
        var atoms: Atoms = undefined;

        atoms.xembed = c.XInternAtom(display, "_XEMBED", c.False);
        atoms.wmdeletewin = c.XInternAtom(display, "WM_DELETE_WINDOW", c.False);
        atoms.netwmname = c.XInternAtom(display, "_NET_WM_NAME", c.False);
        atoms.netwmiconname = c.XInternAtom(display, "_NET_WM_ICON_NAME", c.False);
        _ = c.XSetWMProtocols(display, window, &atoms.wmdeletewin, 1);

        atoms.netwmpid = c.XInternAtom(display, "_NET_WM_PID", c.False);

        // win.mode = MODE_NUMLOCK;

        //==================atom ======================//
        //============================================//

        var pty = try justty.Pty.open(initial_size);

        errdefer pty.deinit();
        const pid = try posix.fork();
        _ = c.XChangeProperty(
            display,
            window,
            atoms.netwmpid,
            c.XA_CARDINAL,
            32,
            c.PropModeReplace,
            @ptrCast(&pid),
            1,
        );
        try pty.exec(pid);
        _ = c.XMapWindow(display, window);
        _ = c.XSync(display, c.False);

        return .{
            .display = display,
            .screen = screen,
            .window = window,
            .font = _font_,
            .pty = pty,
            .pid = pid,
            .vis = visual,
            .colormap = cmap,
            .win = win,
            .dc = dc,
            .allocator = allocator,
            .buf = buf,
            .specbuf = specbuf,
            .draw = draw,
            .cursor = cursor,
            .atoms = atoms,
            .xmousebg = xmousebg,
            .xmousefg = xmousefg,
            .gc_values = gcvalues,
            .attrs = attrs,
        };
    }

    inline fn sixd_to_16bit(x: u3) u16 {
        return @as(u16, @intCast(if (x == 0) 0 else 0x3737 + 0x2828 * @as(u16, @intCast(x))));
    }

    inline fn xloadcolor(
        i: usize,
        color_name: ?[*:0]u8,
        ncolor: *c.XftColor,
        display: *c.Display,
        vis: [*c]c.Visual,
        cmap: c.Colormap,
    ) bool {
        var color: c.XRenderColor = undefined;
        color.alpha = 0xffff;

        const name = color_name orelse blk: {
            if (16 <= i and i <= 255) {
                if (i < 6 * 6 * 6 + 16) {
                    const step = i - 16;
                    color.red = sixd_to_16bit(@intCast((step / 36) % 6));
                    color.green = sixd_to_16bit(@intCast((step / 6) % 6));
                    color.blue = sixd_to_16bit(@intCast((step / 1) % 6));
                } else {
                    color.red = @intCast(0x0808 + 0x0a0a * (i - (6 * 6 * 6 + 16)));
                    color.green = color.red;
                    color.blue = color.red;
                }
                return c.XftColorAllocValue(display, vis, cmap, &color, ncolor) != 0;
            } else break :blk c.colorname[i];
        };
        return c.XftColorAllocName(display, vis, cmap, name, ncolor) != 0;
    }

    // Error set for xgetcolor
    const XGetColorError = error{
        InvalidColorIndex,
    };

    /// Retrieves the RGB components of the color at index x from dc.col.
    /// Parameters:
    /// - x: The color index to retrieve.
    /// - r: Pointer to store the red component (0-255).
    /// - g: Pointer to store the green component (0-255).
    /// - b: Pointer to store the blue component (0-255).
    /// Returns: void on success, or an error if the index is out of bounds.
    pub fn xgetcolor(dc: *DC, x: i32, r: *u8, g: *u8, b: *u8) XGetColorError!void {
        // Check if x is within bounds (BETWEEN(x, 0, dc.collen - 1))
        if (x < 0 or x >= @as(i32, @intCast(dc.collen))) {
            return error.InvalidColorIndex;
        }

        // Extract RGB components, shifting from 16-bit (0xFFFF) to 8-bit (0xFF)
        const color = dc.col[@intCast(x)].color;
        r.* = @intCast(color.red >> 8);
        g.* = @intCast(color.green >> 8);
        b.* = @intCast(color.blue >> 8);
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

        var buffer: [8024]u8 = undefined;

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
        // var bg_color: c.XftColor = undefined;
        // _ = c.XftColorAllocName(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), "black", &bg_color);
        // defer c.XftColorFree(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), &bg_color);

        c.XftDrawRect(self.draw, &self.dc.col[c.defaultbg], 0, 0, self.win.w, self.win.h);

        // var fg_color: c.XftColor = undefined;
        // _ = c.XftColorAllocName(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), "white", &fg_color);
        // defer c.XftColorFree(self.display, c.XDefaultVisual(self.display, self.screen), c.XDefaultColormap(self.display, self.screen), &fg_color);

        var y: i32 = self.font.ascent;
        var start: usize = 0;
        while (start < self.output_len) {
            var end = start;
            while (end < self.output_len and self.output[end] != '\n') end += 1;
            c.XftDrawString8(self.draw, &self.dc.col[c.defaultfg], self.font, 10, y, self.output[start..end].ptr, @intCast(end - start));
            y += self.font.height;
            start = end + 1;
        }
        _ = c.XCopyArea(self.display, self.buf, self.window, self.dc.gc, 0, 0, self.win.w, self.win.h, 0, 0);

        _ = c.XFlush(self.display);
    }

    pub fn deinit(self: *Self) void {
        self.pty.deinit();
        // self.allocator.free(self.dc.col);
        // self.allocator.free(self.specbuf);
        for (&self.dc.col) |*color| {
            c.XftColorFree(self.display, self.vis, self.colormap, color);
        }
        _ = c.XftDrawDestroy(self.draw);
        _ = c.XftFontClose(self.display, self.font);
        _ = c.XDestroyWindow(self.display, self.window);
        _ = c.XCloseDisplay(self.display);

        _ = c.XFreePixmap(self.display, self.buf);
        _ = c.XFreeGC(self.display, self.dc.gc);
    }
};
