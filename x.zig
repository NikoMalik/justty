const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const justty = @import("justty.zig");
// const font = @import("font.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const data_structs = @import("datastructs.zig");
const assert = std.debug.assert;
const unicode = std.unicode.utf8ValidCodepoint;
const font = @import("xcb_font.zig");
//*root window - its This is the root window of the X11 display, covering the entire screen.
// It is controlled by the window manager and serves as a parent for all other windows in the application.
//It is not directly involved in rendering, but provides a coordinate system and context for other windows.

//*main_window The main terminal window containing design elements (title bar, frames) that are usually added by the window manager.
// It is the parent of vt_window.
//Responsible for interaction with the window manager (e.g. resize, move, focus).
// (text, cursor) are displayed and user inputs (keys, mouse) are processed

//root_window *width propery and more*
//└── main_window *text, cursor,visual8
pub fn ATTRCMP(a: Glyph, b: Glyph) bool {
    return a.mode.eql(b.mode) and
        a.fg_index == b.fg_index and
        a.bg_index == b.bg_index;
}
pub inline fn safeCast(c_ulong_val: c_ulong) !i16 {
    return if (c_ulong_val > @as(c_ulong, @intCast(std.math.maxInt(i16))))
        error.Overflow
    else if (c_ulong_val < @as(c_ulong, @intCast(std.math.minInt(i16))))
        error.Underflow
    else
        @intCast(c_ulong_val);
}

pub inline fn safeLongToI16(value: c_long) !i16 {
    return if (value > std.math.maxInt(i16))
        error.Overflow
    else if (value < std.math.minInt(i16))
        error.Underflow
    else
        @intCast(value);
}

pub const XcbError = error{
    GeometryRequestFailed,
    NullGeometryReply,
};

pub fn get_drawable_size(conn: *c.xcb_connection_t, drawable: c.xcb_drawable_t) !c.xcb_rectangle_t {
    const cookie = c.xcb_get_geometry(conn, drawable);

    var err: ?*c.xcb_generic_error_t = null;
    const geom = c.xcb_get_geometry_reply(conn, cookie, &err);

    if (err != null) {
        std.log.err("XCB geometry error: {}", .{err.?.error_code});
        return XcbError.GeometryRequestFailed;
    }
    defer std.c.free(geom);

    if (geom == null) {
        return XcbError.NullGeometryReply;
    }

    return c.xcb_rectangle_t{
        .width = geom.?.*.width,
        .height = geom.?.*.height,
        .x = geom.?.*.x,
        .y = geom.?.*.y,
    };
}
const Key = packed struct(u64) {
    key_sym: c.xcb_keysym_t,
    mode: u32,
};

pub const masks = union(enum(u32)) {

    // mainWinMode
    pub const WINDOW_WM: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_BORDER_PIXEL | c.XCB_CW_BIT_GRAVITY | c.XCB_CW_COLORMAP;
    pub const CHILD_EVENT_MASK: u32 = c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE | c.XCB_EVENT_MASK_BUTTON_MOTION;

    pub const WINDOW_CURSOR: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_CURSOR;
};

const elements = enum(u8) {
    COPY_FROM_PARENT = c.XCB_COPY_FROM_PARENT,
};

const GLyphMode = data_structs.IntegerBitSet(13, Glyph_flags);

const WinMode = data_structs.IntegerBitSet(19, WinModeFlags);

const TermMode = data_structs.IntegerBitSet(7, TermModeFlags);

const CursorMode = data_structs.IntegerBitSet(3, CursorFlags);

const Glyph_flags = enum(u4) {
    ATTR_NULL = 0,
    ATTR_BOLD = 1,
    ATTR_FAINT = 2,
    ATTR_ITALIC = 3,
    ATTR_UNDERLINE = 4,
    ATTR_BLINK = 5,
    ATTR_REVERSE = 6,
    ATTR_INVISIBLE = 7,
    ATTR_STRUCK = 8,
    ATTR_WRAP = 9,
    ATTR_WIDE = 10,
    ATTR_WDUMMY = 11,
    ATTR_BOLD_FAINT = 12,
};

const CursorFlags = enum(u2) {
    CURSOR_DEFAULT = 0,
    CURSOR_WRAPNEXT = 1,
    CURSOR_ORIGIN = 2,
};

const TermModeFlags = enum(u3) {
    MODE_WRAP = 0,
    MODE_INSERT = 1,
    MODE_ALTSCREEN = 2,
    MODE_CRLF = 3,
    MODE_ECHO = 4,
    MODE_PRINT = 5,
    MODE_UTF8 = 6,
};

const WinModeFlags = enum(u5) {
    MODE_VISIBLE = 0,
    MODE_FOCUSED = 1,
    MODE_APPKEYPAD = 2,
    MODE_MOUSEBTN = 3,
    MODE_MOUSEMOTION = 4,
    MODE_REVERSE = 5,
    MODE_KBDLOCK = 6,
    MODE_HIDE = 7,
    MODE_APPCURSOR = 8,
    MODE_MOUSESGR = 9,
    MODE_8BIT = 10,
    MODE_BLINK = 11,
    MODE_FBLINK = 12,
    MODE_FOCUS = 13,
    MODE_MOUSEX10 = 14,
    MODE_MOUSEMANY = 15,
    MODE_BRCKTPASTE = 16,
    MODE_NUMLOCK = 17,
    MODE_MOUSE = 18,
};

pub const ascii_printable =
    \\ !\"#$%&'()*+,-./0123456789:;<=>?
    \\ @ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_
    \\ `abcdefghijklmnopqrstuvwxyz{|}~
;

pub const VisualData = struct {
    visual: *c.xcb_visualtype_t,
    visual_depth: u8,

    const Self = @This();

    pub fn init(screen: *c.xcb_screen_t) !Self {
        var depth_iter = c.xcb_screen_allowed_depths_iterator(screen);
        while (depth_iter.rem != 0) {
            if (depth_iter.data.*.depth == screen.*.root_depth) {
                var visual_iter = c.xcb_depth_visuals_iterator(depth_iter.data);
                while (visual_iter.rem != 0) {
                    if (visual_iter.data.*.visual_id == screen.*.root_visual) {
                        return Self{
                            .visual = visual_iter.data,
                            .visual_depth = depth_iter.data.*.depth,
                        };
                    }
                    c.xcb_visualtype_next(&visual_iter);
                }
            }
            c.xcb_depth_next(&depth_iter);
        }
        return error.NoMatchingVisual;
    }
};

const S = struct {
    var main_window_id: c.xcb_window_t = 0;
    var main_initialized: bool = false; // make in flags if has more  8
    var root_window: c.xcb_window_t = 0;
    var root_initialized: bool = false;
};

// Purely graphic info //
const TermWindow = struct {
    mode: WinMode,
    ///*tty width and height */
    tty_grid: Grid, // tw и th → tty_size.w and tty_size.h
    //*window width and height */
    win_size: Size, // w и h → win_size.width and win_size.height
    // /*char height and width */
    char_size: Size, // cw и ch → char_size.w and char_size.h
    cursor: u16 = c.CURSORSHAPE,
};

const Font = struct {
    face: font.XRenderFont,
    size: Size,
    ascent: u32,
};
// Drawing Context
const DC = struct {
    col: [260]Color, // len: usize,
    font: Font,
    gc: c.xcb_gcontext_t,
};

/// size pixels (windows, symbols, fonts).
pub const Size = packed struct(u32) {
    width: u16,
    height: u16,
};

/// count
pub const Grid = packed struct(u32) {
    cols: u16,
    rows: u16,
};

pub const Position = packed struct(u32) {
    x: u16,
    y: u16,
};

pub const Bounds = packed struct(u32) {
    top: u16,
    bottom: u16,
};

/// limitation or indexes (for example, min value or index of line ).
pub const Constraints = packed struct(u32) {
    min: u16, // min value (for example lines)
    index: u16, // index (for example index of line)
};

//Represents a single “cell” of the screen with the symbol and its attributes:
// grid based interfaces
pub const Glyph = struct {
    mode: GLyphMode, // flags BOLD,ITALIC and more
    u: u32 = 0, //unicode  char
    fg_index: u9 = @as(u9, @intCast(c.defaultfg)), //foreground
    bg_index: u9 = @as(u9, @intCast(c.defaultbg)), //background
};

const DirtySet = std.bit_set.ArrayBitSet(u16, c.MAX_ROWS);

const Term = struct {
    mode: TermMode, // Terminal modes
    /// Allocator
    allocator: Allocator,
    //(e.g., line auto-transfer, alternate screen, UTF-8).
    dirty: DirtySet, //Bitmask to keep track of “dirty” rows that need to be redrawn.
    line: [c.MAX_ROWS][c.MAX_COLS]Glyph, // Array of strings with fixed size MAX_ROWS
    alt: [c.MAX_ROWS][c.MAX_COLS]Glyph, // alt array(for example vim,htop) of strings with fixes size MAX_ROWS

    //For an 80x24 character terminal with a Glyph size of 16 bytes, one screen takes ~30 KB.
    //Two screens - ~60 KB. can we use union for 60kb? mb not
    // cols,rows
    size_grid: Grid, // Grid size (cols, rows)
    cursor: TCursor, //cursor
    tabs: [c.MAX_COLS]u8,
    ocx: u16 = 0, // Previous cursor position X
    ocy: u16 = 0, // Previous cursor position Y
    top: u16 = 0, // Upper scroll limit
    bot: u16 = 0, // Lower scroll limit
    esc: u16 = 0, // Status of ESC sequences
    charset: u16 = 0, // Current encoding
    icharset: u16 = 0, // Encoding index
    trantbl: [4]u8, // /* charset table translation */
    cursor_visible: bool, // Cursor visibility

    pub fn init(allocator: Allocator, cols: u16, rows: u16) !Term {
        // const cols_u16 = @as(u16, @intCast(c.cols)); // u8
        // const rows_u16 = @as(u16, @intCast(c.rows)); // u8

        var term: Term = .{
            .mode = TermMode.initEmpty(),
            .allocator = allocator,
            .dirty = DirtySet.initEmpty(),
            .line = undefined, //later
            .alt = undefined, //later
            .size_grid = Grid{ .cols = cols, .rows = rows },
            .cursor = TCursor{
                .attr = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() },
                .pos = Position{ .x = 0, .y = 0 },
                .state = CursorMode.initEmpty(),
            },
            .tabs = undefined,
            .ocx = 0,
            .ocy = 0,
            .top = 0,
            .bot = rows - 1,
            .esc = 0,
            .charset = 0,
            .icharset = 0,
            .trantbl = [_]u8{0} ** 4,
            .cursor_visible = true,
        };

        for (&term.line) |*row| {
            row.* = [_]Glyph{Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() }} ** c.MAX_COLS;
        }
        for (&term.alt) |*row| {
            row.* = [_]Glyph{Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() }} ** c.MAX_COLS;
        }
        term.tabs = [_]u8{0} ** c.MAX_COLS;
        return term;
    }

    inline fn handle_esc_sequence(self: *Term, sequence: []const u8) void {
        if (util.compare(sequence, "[?1049h")) {
            self.mode.set(.MODE_ALTSCREEN);
        } else if (util.compare(u8, sequence, "[?1049l")) {
            self.mode.unset(.MODE_ALTSCREEN);
        }
    }
    //FIXME:unused
    inline fn reallocScreen(self: *Term, screen: []Glyph, new_cols: u16, new_rows: u16) !void {
        for (screen[0..new_rows]) |*row| {
            const old_len = row.len;
            row.* = try self.allocator.realloc(row.*, new_cols);
            if (new_cols > old_len) {
                @memset(row.*[old_len..new_cols], Glyph{
                    .u = ' ',
                    .fg_index = c.defaultfg,
                    .bg_index = c.defaultbg,
                    .mode = GLyphMode.initEmpty(),
                });
            }
        }
    }

    inline fn swapscreen(self: *Term) void {
        const temp = self.line;
        self.line = self.alt;
        self.alt = temp;
        self.mode.toggle(.MODE_ALTSCREEN);
        self.fulldirt();
    }

    fn resize(self: *Term, col: u16, rows: u16) !void {
        const new_cols = @max(2, @min(col, c.MAX_COLS));
        const new_rows = @max(2, @min(rows, c.MAX_ROWS));

        if (col < 2 or rows < 2) {
            if (comptime util.isDebug) {
                std.log.warn("Terminal size too small: requested cols={}, rows={}; clamping to cols={}, rows={}", .{ col, rows, new_cols, new_rows });
            }
        }

        if (self.size_grid.cols == new_cols and self.size_grid.rows == new_rows) return;

        self.size_grid.cols = new_cols;
        self.size_grid.rows = new_rows;

        self.cursor.pos.x = @min(self.cursor.pos.x, new_cols - 1);
        self.cursor.pos.y = @min(self.cursor.pos.y, new_rows - 1);

        self.dirty.setRangeValue(.{ .start = 0, .end = new_rows }, true);
    }
    fn setdirtattr(self: *Term, attr: Glyph_flags) void {
        var i: u32 = 0;
        while (i < self.size_grid.rows) : (i += 1) {
            var j: u32 = 0;
            while (j < self.size_grid.cols) : (j += 1) {
                if (self.line[i][j].mode.isSet(attr)) {
                    self.set_dirt(i, i);
                    break;
                }
            }
        }
    }

    //for example from 5 to 10 lines are dirty
    fn set_dirt(self: *Term, top: u16, bot: u16) void {

        // check valid
        if (top > bot or bot >= self.size_grid.rows) {
            return;
        }

        // set dirty from top to bot
        const start = top;
        const end = @min(bot, self.size_grid.rows - 1); // set limit to bot
        self.dirty.setRangeValue(.{ .start = start, .end = end + 1 }, true); // bot + 1, because end excluded
    }

    fn fulldirt(self: *Term) void {
        self.set_dirt(0, self.size_grid.rows - 1);
    }

    fn linelen(self: *Term, y: u32) u32 {
        var i = self.size_grid.cols;

        if (self.line[y][i - 1].mode.isSet((Glyph_flags.ATTR_WRAP)))
            return i;
        while (i > 0 and self.line[y][i - 1].u == ' ')
            i -= 1;

        return i;
    }

    fn parse_esc(self: *Term, data: []const u8) void {
        for (data) |byte| {
            switch (self.esc) {
                0 => {
                    if (byte == 0x1B) self.esc = 1;
                },
                1 => {
                    if (byte == '[') self.esc = 2 else self.esc = 0;
                },
                2 => {
                    switch (byte) {
                        'J' => {
                            const screen = if (self.mode.isSet((TermModeFlags.MODE_ALTSCREEN))) &self.alt else &self.line;
                            for (screen[0..self.size_grid.rows]) |*row| {
                                for (row[0..self.size_grid.cols]) |*glyph| {
                                    glyph.* = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
                                }
                            }
                            self.dirty.setRangeValue(.{ .start = 0, .end = self.size_grid.rows }, true);
                            self.esc = 0;
                        },
                        'H' => {
                            self.cursor.pos = Position{ .x = 0, .y = 0 };
                            self.esc = 0;
                        },
                        else => self.esc = 0,
                    }
                },
                else => self.esc = 0,
            }
        }
    }
};

const Selection = struct {
    xtarget: c.xcb_atom_t,
    clipcopy: union {
        primary: ?[]u8,
        clipboard: ?[]u8,
    },
    tclick1: c.timespec,
    tclick2: c.timespec,
};

//current cursor
const TCursor = struct {
    attr: Glyph, //current char attrs
    pos: Position, // pos.x and pos.y for cursor position
    state: CursorMode,

    // pub fn selected(self: *TCursor, x: u16, y: u16) bool {
    //     if (self.state.isSet(.CURSOR_DEFAULT) or self.pos.y == Selection.no_sel or sel.alt != term.mode.get(.Altscreen))
    //         return false;

    //     if (sel.type == .Rectangular)
    //         return sel.nb.y <= y and y <= sel.ne.y;

    //     return (sel.nb.y <= y and y <= sel.ne.y) //
    //     and (y != sel.nb.y or x >= sel.nb.x) //
    //     and (y != sel.ne.y or x <= sel.ne.x);
    // }
};

pub const Arg = union {
    i: i32,
    ui: u32,
    f: f64,
    v: ?*anyopaque,
    none: void,
    //current char attrs
    pub const None = &Arg{ .none = {} };
};

const RenderColor = packed struct(u64) {
    /// Red color channel. */
    red: u16,
    // Green color channel. */
    green: u16,
    // Blue color channel. */
    blue: u16,
    // Alpha color channel. */
    alpha: u16,

    pub inline fn cval(self: *RenderColor) *c.xcb_render_color_t {
        return @ptrCast(@alignCast(self));
    }
};

const Color = packed struct(u96) {
    pixel: u32,
    color: RenderColor,
};

pub inline fn TIMEDIFF(t1: c.struct_timespec, t2: c.struct_timespec) c_long {
    return (t1.tv_sec - t2.tv_sec) * 1000 + @divTrunc(t1.tv_nsec - t2.tv_nsec, 1_000_000);
}

inline fn get_colormap(conn: *c.xcb_connection_t) c.xcb_colormap_t {
    return c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data.*.default_colormap;
}

pub inline fn create_gc(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    win: c.xcb_drawable_t,
    fg: u32,
    bg: u32,
) c.xcb_gcontext_t {
    var out_gc: c.xcb_gcontext_t = gc;
    if (out_gc == 0) {
        out_gc = c.xcb_generate_id(conn);
    }

    // Create the GC, check for errors
    if (comptime util.isDebug) {
        const create_cookie = c.xcb_create_gc_checked(conn, out_gc, win, 0, null);
        XlibTerminal.testCookie(
            create_cookie,
            conn,
            "cannot create gc in create_gc",
        );

        const value_mask: u32 = c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
        const values: [3]u32 = .{
            fg | 0xff000000,
            bg | 0xff000000,
            0,
        };
        _ = c.xcb_change_gc(conn, out_gc, value_mask, &values);

        return out_gc;
    } else {
        _ = c.xcb_create_gc(
            conn,
            out_gc,
            win,
            0,
            null,
        );

        const value_mask: u32 = c.XCB_GC_FOREGROUND | c.XCB_GC_BACKGROUND | c.XCB_GRAPHICS_EXPOSURE;
        const values: [3]u32 = .{
            fg | 0xff000000,
            bg | 0xff000000,
            0,
        };
        _ = c.xcb_change_gc(conn, out_gc, value_mask, &values);

        return out_gc;
    }
}

pub inline fn set_cardinal_property(
    conn: *c.xcb_connection_t,
    prop_name: []const u8,
    value: u32,
) void {
    const prop = get_atom(conn, prop_name);
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        get_main_window(conn),
        prop,
        c.XCB_ATOM_CARDINAL,
        32,
        1,
        &value,
    );
}

//TODO:function for epoll events with getting fd from conn,MAKE ALL XCB CALLS CLEAR,MEMORY LEAKS NOW,CACHE atoms,change doc about windows
// esc commansd \e[2J to clear the screen, \e[H to move the cursor).
// ring buffer and event loop for pty read

pub inline fn get_geometry_reply(xc: *c.xcb_connection_t, cookie: c.xcb_get_geometry_cookie_t) !TermWindow {
    const reply = c.xcb_get_geometry_reply(xc, cookie, null) orelse {
        std.log.err("Could not get geometry", .{});
        return error.CannotGetGeometry;
    };
    defer std.c.free(reply);
    const height = reply.*.height;
    return TermWindow{
        .mode = WinMode.initEmpty(),
        .tty_grid = Grid{ .cols = 0, .rows = 0 },
        .win_size = Size{ .width = reply.*.width, .height = height },
        .char_size = Size{ .width = 0, .height = 0 },
        .cursor = 0,
    };
}
pub inline fn get_geometry(xc: *c.xcb_connection_t, f: Font) !TermWindow {
    var geo = try get_geometry_reply(xc, c.xcb_get_geometry(xc, get_main_window(xc)));
    geo.win_size.width -= geo.win_size.width % f.size.width;
    geo.win_size.height -= geo.win_size.height % f.size.height;

    return geo;
}

// Resize window and its subwindows
pub fn resize_window(conn: *c.xcb_connection_t, f: Font) void {
    const geo = get_geometry(conn, f) catch |err| {
        std.log.err("Failed to get geometry: {}", .{err});
        return;
    };
    const vt_values = [_]u16{ geo.win_size.width, geo.win_size.height };
    _ = c.xcb_configure_window(conn, get_main_window(conn), c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &vt_values);
}

pub inline fn map_windows(
    conn: *c.xcb_connection_t,
    f: Font,
) void {
    _ = c.xcb_map_window(conn, get_main_window(conn));
    _ = c.xcb_map_subwindows(conn, get_main_window(conn));
    resize_window(conn, f);
}

pub inline fn set_windows_name(
    conn: *c.xcb_connection_t,
    win: c.xcb_window_t,
    name: []const u8,
) void {
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        win,
        c.XCB_ATOM_WM_NAME,
        c.XCB_ATOM_STRING,
        8,
        @intCast(name.len),
        name.ptr,
    );
}

inline fn set_icon_name(xc: *c.xcb_connection_t, win: c.xcb_window_t, name: []const u8) void {
    _ = c.xcb_change_property(
        xc,
        c.XCB_PROP_MODE_REPLACE,
        win,
        c.XCB_ATOM_WM_ICON_NAME,
        c.XCB_ATOM_STRING,
        8,
        @intCast(name.len),
        name.ptr,
    );
}

pub fn get_root_window(conn: *c.xcb_connection_t) c.xcb_window_t {
    if (!S.root_initialized) {
        const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data;
        S.root_window = screen.*.root;
        S.root_initialized = true;
    }
    return S.root_window;
}

pub fn get_main_window(conn: *c.xcb_connection_t) c.xcb_window_t {
    if (!S.main_initialized) {
        S.main_window_id = c.xcb_generate_id(conn);
        S.main_initialized = true;
    }
    return S.main_window_id;
}

pub inline fn get_atom(
    conn: *c.xcb_connection_t,
    name: []const u8,
) c.xcb_atom_t {
    const r = c.xcb_intern_atom_reply(conn, c.xcb_intern_atom(
        conn,
        @intFromBool(false),
        @intCast(name.len),
        name.ptr,
    ), null);
    defer std.c.free(r);
    const a = r.*.atom;
    return a;
}

pub inline fn get_wm_del_win(
    conn: *c.xcb_connection_t,
) c.xcb_atom_t {
    const a = get_atom(conn, "WM_DELETE_WINDOW");
    _ = c.xcb_change_property(conn, c.XCB_PROP_MODE_REPLACE, get_main_window(conn), get_atom(conn, "WM_PROTOCOLS"), c.XCB_ATOM_ATOM, 32, 1, &a);
    return a;
}

// pub inline fn open_font(
//     conn: *c.xcb_connection_t
//     font_id: c.xcb_font_t,
// ) bool {}

pub inline fn set_utf8_prop(
    conn: *c.xcb_connection_t,
    prop: c.xcb_atom_t,
    value: []const u8,
) void {
    const utf8 = get_atom(conn, "UTF8_STRING");
    // const prop = get_atom(conn, prop_name);
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        get_main_window(conn),
        prop,
        utf8,
        8,
        @intCast(value.len),
        value.ptr,
    );
}

pub inline fn get_clipboard(
    conn: *c.xcb_connection_t,
) c.xcb_atom_t {
    const a = get_atom(conn, "CLIBOARD");
    return a;
}

pub inline fn set_property(
    conn: *c.xcb_connection_t,
    atom: c.xcb_atom_t,
    size: u32,
    value: *anyopaque,
) void {
    _ = c.xcb_change_property(
        conn,
        c.XCB_PROP_MODE_REPLACE,
        get_main_window(conn),
        atom,
        c.XCB_ATOM_STRING,
        8,
        size,
        value,
    );
}

pub inline fn create_main_window(
    conn: *c.xcb_connection_t,
    root: c.xcb_window_t,
    win: TermWindow,
    values: []u32,
    mask: u32,
    visual: VisualData,
) void {
    const window = get_main_window(conn);
    const cookie = c.xcb_create_window_checked(
        conn,
        c.XCB_COPY_FROM_PARENT,
        window,
        root,
        0,
        0,
        @intCast(win.win_size.width),
        @intCast(win.win_size.height),
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        visual.visual.*.visual_id,
        mask,
        values.ptr,
    );
    XlibTerminal.testCookie(cookie, conn, "cannot create main window");
    S.main_window_id = window;
    S.main_initialized = true;
}

pub inline fn get_cursor(
    conn: *c.xcb_connection_t,
    name: [*c]const u8,
) c.xcb_cursor_t {
    var ctx: ?*c.xcb_cursor_context_t = undefined;
    const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data;

    _ = c.xcb_cursor_context_new(conn, screen, &ctx);
    const cursor: c.xcb_cursor_t = c.xcb_cursor_load_cursor(ctx, name);
    _ = c.xcb_cursor_context_free(ctx);
    return cursor;
}

pub inline fn set_cursor( //free
    conn: *c.xcb_connection_t,
    font_id: c.xcb_font_t,
) c.xcb_cursor_t {
    const cursor_id = c.xcb_generate_id(conn);
    errdefer _ = c.xcb_free_cursor(conn, cursor_id);
    _ = c.xcb_create_glyph_cursor(
        conn,
        cursor_id,
        font_id,
        font_id,
        c.CURSORSHAPE,
        c.CURSORSHAPE + 1,
        0xffff,
        0xffff,
        0xffff,
        0,
        0,
        0,
    );

    _ = c.xcb_change_window_attributes(
        conn,
        get_main_window(conn),
        c.XCB_CW_CURSOR,
        &cursor_id,
    );
    return cursor_id;
}

pub inline fn get_cmap_from_winattr(
    conn: *c.xcb_connection_t,
    wac: c.xcb_get_window_attributes_cookie_t,
) c.xcb_colormap_t {
    const reply: *c.xcb_get_window_attributes_reply_t = c.xcb_get_window_attributes_reply(conn, wac, null);
    const cmap: c.xcb_colormap_t = reply.colormap;
    std.c.free(reply);
    return cmap;
}

// pub inline fn set_fg(conn: *c.xcb_connection_t, gc: c.xcb_gcontext_t, p: u32) u32 {
//     _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &[_]u32{p});
//     return p;
// }

pub inline fn set_fg(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    p: u32,
) void {
    const cookie = c.xcb_change_gc_checked(conn, gc, c.XCB_GC_FOREGROUND, &[_]u32{p});
    XlibTerminal.testCookie(cookie, conn, "cannot set foreground color");
}

pub inline fn set_bg(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    p: u32,
) void {
    const cookie = c.xcb_change_gc_checked(conn, gc, c.XCB_GC_BACKGROUND, &[_]u32{p});
    XlibTerminal.testCookie(cookie, conn, "cannot set background color");
}
// pub inline fn set_bg(conn: *c.xcb_connection_t, gc: c.xcb_gcontext_t, p: u32) u32 {
//     _ = c.xcb_change_gc(conn, gc, c.XCB_GC_BACKGROUND, &[_]u32{p});
//     return p;
// }

pub inline fn get_rgb_pixel(
    conn: *c.xcb_connection_t,
    cmap: c.xcb_colormap_t,
    r: u16,
    g: u16,
    b: u16,
) u32 {
    const color: c.xcb_alloc_color_cookie_t = c.xcb_alloc_color(
        conn,
        cmap,
        @intCast(r),
        @intCast(g),
        @intCast(b),
    );
    const rpl_color: *c.xcb_alloc_color_reply_t = c.xcb_alloc_color_reply(conn, color, null);
    defer std.c.free(rpl_color);
    const p = rpl_color.pixel;
    return @intCast(p);
}

pub fn color_alloc_value(
    conn: *c.xcb_connection_t,
    visual: *c.xcb_visualtype_t,
    cmap: c.xcb_colormap_t,
    color: *RenderColor,
    result: *Color,
) bool {
    if (visual._class == c.XCB_VISUAL_CLASS_TRUE_COLOR) {
        const red_shift = @as(u5, @intCast(@ctz(visual.red_mask)));
        const red_len = @as(u5, @intCast(@popCount(visual.red_mask)));
        const green_shift = @as(u5, @intCast(@ctz(visual.green_mask)));
        const green_len = @as(u5, @intCast(@popCount(visual.green_mask)));
        const blue_shift = @as(u5, @intCast(@ctz(visual.blue_mask)));
        const blue_len = @as(u5, @intCast(@popCount(visual.blue_mask)));

        const red_part = (@as(u32, color.red) >> @as(u5, 16 - red_len)) << red_shift;
        const green_part = (@as(u32, color.green) >> @as(u5, 16 - green_len)) << green_shift;
        const blue_part = (@as(u32, color.blue) >> @as(u5, 16 - blue_len)) << blue_shift;

        result.pixel = red_part | green_part | blue_part;

        if (visual.bits_per_rgb_value == 32) {
            result.pixel |= (@as(u32, color.alpha >> 8) << 24);
        }
    } else {
        const cookie = c.xcb_alloc_color(
            conn,
            cmap,
            @truncate(color.red),
            @truncate(color.green),
            @truncate(color.blue),
        );

        if (c.xcb_alloc_color_reply(conn, cookie, null)) |reply| {
            defer std.c.free(reply);
            result.pixel = reply.*.pixel;
        } else {
            return false;
        }
    }

    result.color = color.*;
    return true;
}

pub inline fn color_alloc_name(conn: *c.xcb_connection_t, cmap: c.xcb_colormap_t, name: [*:0]const u8, result: *Color) bool {
    const cookie = c.xcb_alloc_named_color(
        conn,
        cmap,
        @intCast(std.mem.len(name)),
        name,
    );

    if (c.xcb_alloc_named_color_reply(conn, cookie, null)) |reply| {
        defer std.c.free(reply);
        result.pixel = reply.*.pixel;
        result.color.red = @as(u16, reply.*.exact_red);
        result.color.green = @as(u16, reply.*.exact_green);
        result.color.blue = @as(u16, reply.*.exact_blue);
        result.color.alpha = 0xffff;
        return true;
    }
    return false;
}

pub inline fn get_pixel(
    conn: *c.xcb_connection_t,
    cmap: c.xcb_colormap_t,
    color: []const u8,
) u32 {
    const color_cookie = c.xcb_alloc_named_color(conn, cmap, @intCast(color.len), color.ptr);

    const reply = c.xcb_alloc_named_color_reply(conn, color_cookie, null);

    defer std.c.free(reply);

    return @intCast(reply.pixel);
}

// pub const struct_xcb_visualtype_t = extern struct {
//     visual_id: xcb_visualid_t = @import("std").mem.zeroes(xcb_visualid_t),
//     _class: u8 = @import("std").mem.zeroes(u8),
//     bits_per_rgb_value: u8 = @import("std").mem.zeroes(u8),
//     colormap_entries: u16 = @import("std").mem.zeroes(u16),
//     red_mask: u32 = @import("std").mem.zeroes(u32),
//     green_mask: u32 = @import("std").mem.zeroes(u32),
//     blue_mask: u32 = @import("std").mem.zeroes(u32),
//     pad0: [4]u8 = @import("std").mem.zeroes([4]u8),
// };

pub inline fn maskbase(m: u32) i16 {
    if (m == 0) return 0;
    var i: i16 = 0;
    var mask = m;
    while (mask & 1 == 0) {
        mask >>= 1;
        i += 1;
    }
    return i;
}

pub inline fn masklen(m: u64) i16 {
    var y = (m >> 1) & 0x3333333333333333;
    y = m - y - ((y >> 1) & 0x3333333333333333);
    y = (y + (y >> 3)) & 0x0707070707070707;
    return @as(i16, @intCast(y % 63));
}

const Atoms = packed struct {
    xembed: c.xcb_atom_t,
    wmdeletewin: c.xcb_atom_t,
    netwmname: c.xcb_atom_t,
    netwmiconname: c.xcb_atom_t,
    netwmpid: c.xcb_atom_t,
};

pub const XlibTerminal = struct {
    //========main struct=========//=
    connection: *c.xcb_connection_t,
    //============================//=
    screen: *c.xcb_screen_t,
    pixmap: c.xcb_pixmap_t,
    allocator: Allocator,
    pty: justty.Pty,
    pid: posix.pid_t,
    visual: VisualData,
    xrender_font: Font,
    // ft: font.FreeType,
    // fc: font.Fontconfig,

    dc: DC,
    term: Term, // Buffer to store pty output
    win: TermWindow,
    output_len: usize = 0, // Length of stored output

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const connection = c.xcb_connect(null, null) orelse return error.CannotOpenDisplay;
        errdefer _ = c.xcb_disconnect(connection);
        if (c.xcb_connection_has_error(connection) != 0) {
            return error.CannotOpenDisplay;
        }

        //getting screen

        const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection)).data;
        const visual_data = try VisualData.init(screen);
        if (comptime util.isDebug) {
            std.log.info("Visual depth: {}, visual_id: {}", .{ visual_data.visual_depth, visual_data.visual.visual_id });
        }

        // const screen = c.XDefaultScreen(display);
        const root = get_root_window(connection);

        const font_query = c.font;
        var xrender_font = try font.XRenderFont.init(connection, allocator, font_query[0..]);
        errdefer xrender_font.deinit();
        std.log.info("Font initialized: query={s}, dpi={d}", .{ font_query[0..], @as(u16, @intFromFloat(xrender_font.dpi)) });
        const pixel_size = font.getPixelSize(xrender_font.pattern, xrender_font.dpi);
        xrender_font.pattern.print();
        // const metrics = face.handle.*.size.*.metrics;
        const metrics = xrender_font.ft.face.?.*.size.*.metrics;
        const cw = @as(u16, @intCast(metrics.x_ppem));
        const ch = @as(u16, @intCast(metrics.y_ppem));
        if (cw > 72 or ch > 72) {
            std.log.err("Character size too large: cw={}, ch={}. Check font pixel size or DPI.", .{ cw, ch });
            return error.InvalidFontMetrics;
        }

        if (cw < 6 or ch < 6) {
            std.log.err("Character size too small: cw={}, ch={}. Check font pixel size or DPI.", .{ cw, ch });
            return error.InvalidFontMetrics;
        }
        // const cw = 12;
        // const ch = 16;
        const ascent = @as(u32, @intFromFloat(pixel_size * 0.8)); // Approximate ascent
        const border_px = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        std.log.info("cw and ch from font: cw={} ch={}", .{ cw, ch });

        // var border_px = @as(u16, @intCast(c.borderpx)); // u16
        const cols_u16 = @as(u16, @intCast(c.cols)); // u8
        const rows_u16 = @as(u16, @intCast(c.rows)); // u8
        if (border_px == 0) {
            border_px = 1;
        }

        const win_width = 2 * border_px + cols_u16 * cw;
        const win_height = 2 * border_px + rows_u16 * ch;
        if (win_width == 0 or win_height == 0 or win_width > 32767 or win_height > 32767) {
            std.log.err("invalid width and height for winsizes: width={}, height={}", .{ win_width, win_height });
            return error.InvalidWindowSize;
        }
        std.log.info("size windows: width={}, height={}", .{ win_width, win_height });
        var win: TermWindow = .{
            .mode = WinMode.initEmpty(),
            .tty_grid = Grid{ .cols = cols_u16, .rows = rows_u16 },
            .win_size = Size{ .width = win_width, .height = win_height },
            .char_size = Size{ .width = cw, .height = ch },
            .cursor = c.CURSORSHAPE,
        };
        const term: Term = try Term.init(allocator, win.tty_grid.cols, win.tty_grid.rows);
        var dc: DC = undefined;
        errdefer _ = c.xcb_free_gc(connection, dc.gc);
        win.mode.set(WinModeFlags.MODE_NUMLOCK);
        // if (comptime util.isDebug) {
        //     if (win.mode.isSet(WinModeFlags.MODE_NUMLOCK)) {
        //         std.log.info("Window is numlock", .{});
        //     }

        dc.font = .{
            .size = Size{ .width = cw, .height = ch },
            .ascent = @intCast(ascent),
            .face = xrender_font,
        };

        for (&dc.col, 0..) |*color, i| {
            if (!xloadcolor(connection, visual_data.visual, i, null, color)) {
                if (i < c.colorname.len and c.colorname[i] != null) {
                    std.log.err("cannot allocate color name={s}", .{c.colorname[i].?});
                    return error.CannotAllocateColor;
                } else {
                    std.log.err("cannot allocate color {}", .{i});
                    return error.CannotAllocateColor;
                }
            }
            if (comptime util.isDebug) {
                std.log.debug("Background color (index {}): pixel={x}, R={}, G={}, B={}", .{
                    i,
                    color.pixel,
                    color.color.red >> 8,
                    color.color.green >> 8,
                    color.color.blue >> 8,
                });
            }
        }

        // const window = get_main_window(connection);

        errdefer _ = c.xcb_destroy_window(
            connection,
            root,
        );
        var values_main = [_]u32{
            dc.col[c.defaultbg].pixel,
            c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_BUTTON_PRESS |
                c.XCB_EVENT_MASK_BUTTON_RELEASE |
                c.XCB_EVENT_MASK_STRUCTURE_NOTIFY | c.XCB_EVENT_MASK_FOCUS_CHANGE | c.XCB_EVENT_MASK_VISIBILITY_CHANGE, // XCB_CW_EVENT_MASK
            dc.col[c.defaultbg].pixel, // border
            c.XCB_GRAVITY_NORTH_WEST, // XCB_CW_BIT_GRAVITY
            get_colormap(connection),
        };

        create_main_window(
            connection,
            root,
            win,
            values_main[0..],
            masks.WINDOW_WM,
            visual_data,
        );

        const window_geo_cookie = c.xcb_get_geometry(connection, get_main_window(connection));
        const window_geo_reply = c.xcb_get_geometry_reply(connection, window_geo_cookie, null);
        if (window_geo_reply == null) {
            std.log.err("cannot get geometry main window", .{});
            return error.CannotGetWindowGeometry;
        }
        defer std.c.free(window_geo_reply);
        const pixmap_depth = window_geo_reply.*.depth;
        std.log.info("depth main window: {}", .{pixmap_depth});

        const pixmap: c.xcb_drawable_t = c.xcb_generate_id(connection);
        const pixmap_cookie = c.xcb_create_pixmap_checked(
            connection,
            pixmap_depth,
            pixmap,
            get_main_window(connection),
            win.win_size.width,
            win.win_size.height,
        );
        if (c.xcb_request_check(connection, pixmap_cookie)) |err| {
            std.log.err("cannot create pixmap in xlibinit, error: {}", .{err.*.error_code});
            return error.CannotCreatePixmap;
        }

        std.log.info("Creating pixmap with depth: {}", .{pixmap_depth});

        dc.gc = c.xcb_generate_id(connection);
        errdefer _ = c.xcb_free_gc(connection, dc.gc);

        const initial_size: justty.winsize = .{ .ws_row = c.rows, .ws_col = c.cols, .ws_xpixel = 0, .ws_ypixel = 0 };

        const atom_del = get_wm_del_win(connection);
        set_windows_name(connection, get_main_window(connection), "justty");
        set_icon_name(connection, get_main_window(connection), "justty");
        var pty = try justty.Pty.open(initial_size);

        errdefer pty.deinit();
        const pid = try posix.fork();
        // set_cardinal_property(connection, "_NET_WM_PID", @intCast(pid));
        _ = c.xcb_change_property(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            root,
            atom_del,
            c.XCB_ATOM_ATOM,
            32,
            1,
            &atom_del,
        );
        // set_property(conn: *c.xcb_connection_t, prop_name: []const u8, value: []const u8)
        _ = try pty.exec(pid);
        map_windows(connection, dc.font);
        errdefer _ = c.xcb_free_pixmap(connection, pixmap);
        dc.gc = create_gc(connection, dc.gc, get_main_window(connection), dc.col[c.defaultfg].pixel, dc.col[c.defaultbg].pixel);
        const rectangle = c.xcb_rectangle_t{
            .x = 0,
            .y = 0,
            .height = win.win_size.height,
            .width = win.win_size.width,
        };
        _ = c.xcb_poly_fill_rectangle(
            connection,
            pixmap,
            dc.gc,
            1,
            &rectangle,
        );

        _ = c.xcb_flush(connection);

        return .{
            .term = term,
            .visual = visual_data,
            // .attrs = attrs,
            // .gc_values = gcvalues,
            .connection = connection,
            .screen = screen,
            // .window = root,
            .pixmap = pixmap,
            .xrender_font = dc.font,
            .allocator = allocator,
            .pty = pty,
            // .atoms = atoms,
            .pid = pid,
            .dc = dc,
            .win = win,
        };
    }

    fn drawSimpleText(self: *Self, x: i16, y: i16, text: []const u8) !void {
        const font_id = c.xcb_generate_id(self.connection);
        _ = c.xcb_open_font(self.connection, font_id, "fixed".len, "fixed".ptr);
        _ = c.xcb_change_gc(self.connection, self.dc.gc, c.XCB_GC_FONT, &font_id);
        _ = c.xcb_image_text_8(self.connection, @intCast(text.len), get_main_window(self.connection), self.dc.gc, x, y, text.ptr);
        _ = c.xcb_close_font(self.connection, font_id);
        _ = c.xcb_flush(self.connection);
    }

    pub fn makeglyphfont(
        self: *Self,
        glyphs: []Glyph,
        specs: []Font,
    ) usize {
        const ff = self.dc.font.face;
        var numspecs: usize = 0;
        for (glyphs) |glyph| {
            if (numspecs >= specs.len) break;
            var fg_color = self.dc.col[glyph.fg_index];
            var bg_color = self.dc.col[glyph.bg_index];
            if (glyph.mode.isSet(.ATTR_REVERSE)) {
                fg_color = self.dc.col[glyph.bg_index];
                bg_color = self.dc.col[glyph.fg_index];
            }
            specs[numspecs] = Font{
                .face = ff,
                .fg = fg_color,
                .bg = bg_color,
                .size = self.dc.font.size,
                .ascent = self.dc.font.ascent,
            };
            numspecs += 1;
        }
        return numspecs;
    }

    fn process_input(self: *XlibTerminal, data: []const u8) void {
        for (data) |byte| {
            if (self.term.esc > 0) {
                self.term.parse_esc(&[_]u8{byte});
            } else if (byte == 0x1B) { // ESC
                self.term.esc = 1;
            } else if (byte >= 32 and byte <= 126) { // Printable character
                const x = self.term.cursor.pos.x;
                const y = self.term.cursor.pos.y;
                if (x < self.term.size_grid.cols and y < self.term.size_grid.rows) {
                    self.term.line[y][x] = Glyph{
                        .u = byte,
                        .fg_index = c.defaultfg,
                        .bg_index = c.defaultbg,
                        .mode = GLyphMode.initEmpty(),
                    };
                    self.term.cursor.pos.x += 1;
                    if (self.term.cursor.pos.x >= self.term.size_grid.cols) {
                        self.term.cursor.pos.x = 0;
                        self.term.cursor.pos.y += 1;
                        if (self.term.cursor.pos.y >= self.term.size_grid.rows) {
                            // Scroll up
                            for (0..self.term.size_grid.rows - 1) |i| {
                                self.term.line[i] = self.term.line[i + 1];
                            }
                            self.term.line[self.term.size_grid.rows - 1] = [_]Glyph{Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() }} ** c.MAX_COLS;
                            self.term.cursor.pos.y -= 1;
                            // Mark all lines as dirty due to scrolling
                            self.term.fulldirt();
                        } else {
                            self.term.set_dirt(y, y);
                        }
                    } else {
                        self.term.set_dirt(y, y);
                    }
                }
            } else if (byte == '\n') { // New line
                self.term.cursor.pos.x = 0;
                self.term.cursor.pos.y += 1;
                if (self.term.cursor.pos.y >= self.term.size_grid.rows) {
                    // Scroll up
                    for (0..self.term.size_grid.rows - 1) |i| {
                        self.term.line[i] = self.term.line[i + 1];
                    }
                    self.term.line[self.term.size_grid.rows - 1] = [_]Glyph{Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() }} ** c.MAX_COLS;
                    self.term.cursor.pos.y -= 1;
                    // Mark all lines as dirty due to scrolling
                    self.term.fulldirt();
                } else {
                    self.term.set_dirt(self.term.cursor.pos.y, self.term.cursor.pos.y);
                }
            }
        }
    }
    pub fn drawline(self: *XlibTerminal, x1: u16, y1: u16, x2: u16) void {
        const row = self.term.line[y1][x1..x2];
        try self.xdrawglyphfontspecs(row, x1, y1, x2 - x1);
    }
    pub fn xdrawglyphfontspecs(self: *XlibTerminal, glyphs: []const Glyph, x: u16, y: u16, len: usize) !void {
        const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        const char_width = self.dc.font.size.width;
        const char_height = self.dc.font.size.height;
        const px = borderpx + x * char_width;
        const py = borderpx + y * char_height + self.dc.font.ascent; // Adjust for ascent

        // Process glyphs in segments with the same attributes
        var start: usize = 0;
        var current_glyph = glyphs[0];
        var text: [c.MAX_COLS]u32 = undefined;
        var text_len: u32 = 0;

        for (glyphs[0..len], 0..) |glyph, i| {
            if (i > 0 and !ATTRCMP(current_glyph, glyph) or i == len - 1) {
                // Include the last glyph if at the end
                const end = if (i == len - 1 and ATTRCMP(current_glyph, glyph)) i + 1 else i;

                // Collect text for the current segment
                text_len = 0;
                for (glyphs[start..end]) |g| {
                    text[text_len] = g.u; // Include all glyphs, even spaces
                    text_len += 1;
                }

                if (text_len > 0) {
                    var fg_color = self.dc.col[current_glyph.fg_index].color;
                    var bg_color = self.dc.col[current_glyph.bg_index].color;
                    if (current_glyph.mode.isSet(.ATTR_REVERSE)) {
                        const temp = fg_color;
                        fg_color = bg_color;
                        bg_color = temp;
                    }

                    // Clear background
                    const mask = c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
                    const values = [_]u32{ get_rgb_pixel(
                        self.connection,
                        get_colormap(self.connection),
                        bg_color.red,
                        bg_color.green,
                        bg_color.blue,
                    ) | 0xff000000, 0 };
                    _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values);

                    const clear_rect = c.xcb_rectangle_t{
                        .x = @intCast(px + (start - x) * char_width),
                        .y = @intCast(py - self.dc.font.ascent),
                        .width = @intCast(char_width * text_len),
                        .height = @intCast(char_height),
                    };
                    _ = c.xcb_poly_fill_rectangle(
                        self.connection,
                        self.pixmap,
                        self.dc.gc,
                        1,
                        &clear_rect,
                    );

                    // Draw text
                    _ = try self.dc.font.face.drawText(
                        self.pixmap,
                        @intCast(px + (start - x) * char_width),
                        @intCast(py),
                        text[0..text_len],
                        fg_color.cval().*,
                    );
                }

                start = i;
                current_glyph = glyph;
            }
        }

        // Handle the last segment if not already processed
        if (start < len and text_len == 0) {
            text_len = 0;
            for (glyphs[start..len]) |g| {
                text[text_len] = g.u;
                text_len += 1;
            }

            if (text_len > 0) {
                var fg_color = self.dc.col[current_glyph.fg_index].color;
                var bg_color = self.dc.col[current_glyph.bg_index].color;
                if (current_glyph.mode.isSet(.ATTR_REVERSE)) {
                    const temp = fg_color;
                    fg_color = bg_color;
                    bg_color = temp;
                }

                // Clear background
                const mask = c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
                const values = [_]u32{ get_rgb_pixel(
                    self.connection,
                    get_colormap(self.connection),
                    bg_color.red,
                    bg_color.green,
                    bg_color.blue,
                ) | 0xff000000, 0 };
                _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values);

                const clear_rect = c.xcb_rectangle_t{
                    .x = @intCast(px + (start - x) * char_width),
                    .y = @intCast(py - self.dc.font.ascent),
                    .width = @intCast(char_width * text_len),
                    .height = @intCast(char_height),
                };
                _ = c.xcb_poly_fill_rectangle(
                    self.connection,
                    self.pixmap,
                    self.dc.gc,
                    1,
                    &clear_rect,
                );

                // Draw text
                _ = try self.dc.font.face.drawText(
                    self.pixmap,
                    @intCast(px + (start - x) * char_width),
                    @intCast(py),
                    text[0..text_len],
                    fg_color.cval().*,
                );
            }
        }
    }
    //TODO:Rendering optimization: The current implementation of xdrawglyphontspecs renders pixel by pixel, which is slow. You can use xcb_put_image to render entire glyphs.
    // fn xdrawglyphfontspecs(self: *XlibTerminal, glyphs: []const Glyph, x: u16, y: u16, len: usize) !void {
    //     const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
    //     const pixel_size =
    //         font.getPixelSize(self.dc.font.face.pattern);
    //     const s_tmp = pixel_size + pixel_size;

    //     const px = borderpx + x * @as(u16, @intFromFloat(pixel_size));
    //     const py = borderpx + y * @as(u16, @intFromFloat(s_tmp));

    //     // Convert glyphs to UTF-32 text
    //     var text: [c.MAX_COLS]u32 = undefined;
    //     var text_len: u32 = 0;
    //     for (glyphs[0..len]) |glyph| {
    //         if (glyph.u != ' ') {
    //             text[text_len] = glyph.u;
    //             text_len += 1;
    //         }
    //     }
    //     if (text_len == 0) return;
    //     const width: u16 = @intFromFloat(
    //         (pixel_size * @as(
    //             f64,
    //             @floatFromInt(text.len),
    //         ) / 1.6) + pixel_size * 0.7,
    //     );
    //     const height: u16 = @intFromFloat(
    //         pixel_size + pixel_size * 0.4,
    //     );

    //     // const utf_holder = font.UtfHolder{ .str = &text, .length = text_len };
    //     const bg_index = if (glyphs[0].bg_index < self.dc.col.len) glyphs[0].bg_index else blk: {
    //         std.log.warn("bg_index {} out of bounds, clamping to defaultbg", .{glyphs[0].bg_index});
    //         break :blk c.defaultbg;
    //     };
    //     const fg_index = if (glyphs[0].fg_index < self.dc.col.len) glyphs[0].fg_index else blk: {
    //         std.log.warn("fg_index {} out of bounds, clamping to defaultfg", .{glyphs[0].fg_index});
    //         break :blk c.defaultfg;
    //     };
    //     // var bg_color = self.dc.col[bg_index].color;
    //     var fg_color = self.dc.col[fg_index].color;

    //     if (comptime util.isDebug) {
    //         std.log.debug("xdrawglyphfontspecs: bg_index={}, fg_index={}, bg_pixel={x}, fg_pixel={x}", .{
    //             bg_index,
    //             fg_index,
    //             self.dc.col[bg_index].pixel,
    //             self.dc.col[fg_index].pixel,
    //         });
    //     }

    //     const mask = c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
    //     const values = [_]u32{
    //         font.xcb_color_to_uint32(fg_color.cval().*) | 0xff000000,
    //         0,
    //     };
    //     _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values);

    //     const clear_rect = c.xcb_rectangle_t{
    //         // .x = @intCast(advance.x),
    //         // .y = @intCast(advance.y),
    //         // .x = 50 - @as(i16, @intCast(self.dc.font.ascent)),
    //         // .y = 60 - @as(i16, @intCast(self.dc.font.ascent)),

    //         .x = 0,
    //         .y = 0,
    //         .width = width,
    //         .height = height,

    //         // .width = self.win.win_size.width,
    //         // .height = self.win.win_size.height,
    //     };
    //     _ = c.xcb_poly_fill_rectangle(
    //         self.connection,
    //         self.pixmap,
    //         self.dc.gc,
    //         1,
    //         &clear_rect,
    //     );

    //     _ = try self.dc.font.face.drawText(
    //         self.pixmap,
    //         @intCast(px),
    //         @intCast(py),
    //         &text,
    //         fg_color.cval().*,
    //     );

    //     // const text_pixmap = try font.createTextPixmap(
    //     //     self.connection,
    //     //     &self.dc.font.face,
    //     //     &text,
    //     //     fg_color.cval().*,
    //     //     bg_color.cval().*,
    //     //     self.dc.font.face.pattern,
    //     //     self.visual,
    //     //     self.dc.gc,
    //     // );

    //     // errdefer _ = c.xcb_free_pixmap(self.connection, text_pixmap);

    //     // _ = c.xcb_copy_area(
    //     //     self.connection,
    //     //     text_pixmap,
    //     //     self.pixmap,
    //     //     self.dc.gc,
    //     //     0,
    //     //     0,
    //     //     @intCast(px),
    //     //     @intCast(py),
    //     //     @intCast(self.dc.font.size.width * len),
    //     //     @intCast(self.dc.font.size.height),
    //     // );

    //     // _ = c.xcb_free_pixmap(self.connection, text_pixmap);
    //     _ = c.xcb_flush(self.connection);
    // }
    //

    pub fn testCookie(cookie: c.xcb_void_cookie_t, conn: *c.xcb_connection_t, err_msg: []const u8) void {
        const e = c.xcb_request_check(conn, cookie);
        if (e != null) {
            std.log.err("ERROR: {s} : {}", .{ err_msg, e.*.error_code });
            c.xcb_disconnect(conn);
            std.process.exit(1);
        }
    }

    inline fn sixd_to_16bit(x: u3) u16 {
        return @as(u16, @intCast(if (x == 0) 0 else 0x3737 + 0x2828 * @as(u16, @intCast(x))));
    }
    inline fn xloadcolor(
        conn: *c.xcb_connection_t,
        // screen: *c.xc_screen_t,
        visual: *c.xcb_visualtype_t,
        i: usize,
        color_name: ?[*:0]const u8,
        color: *Color,
    ) bool {
        const name = color_name orelse blk: {
            if (16 <= i and i <= 255) {
                var xcolor: RenderColor = .{
                    .alpha = 0xffff,
                    .red = 0,
                    .green = 0,
                    .blue = 0,
                };

                if (i < 6 * 6 * 6 + 16) {
                    const step = i - 16;
                    xcolor.red = sixd_to_16bit(@intCast((step / 36) % 6));
                    xcolor.green = sixd_to_16bit(@intCast((step / 6) % 6));
                    xcolor.blue = sixd_to_16bit(@intCast(step % 6));
                } else {
                    const val = (@as(
                        u16,
                        (0x0808 + 0x0a0a * @as(
                            u16,
                            @intCast(i - (6 * 6 * 6 + 16)),
                        )) >> 8,
                    ));
                    xcolor.red = val;
                    xcolor.green = val;
                    xcolor.blue = val;
                }
                return color_alloc_value(
                    conn,
                    visual,
                    get_colormap(conn),
                    &xcolor,
                    color,
                );
            }
            break :blk c.colorname[i];
        };

        if (name[0] == '#') {
            const hex_str = name[1..7];
            var rgb: u24 = 0;
            if (std.fmt.hexToBytes(std.mem.asBytes(&rgb), hex_str)) |_| {
                var xcolor = RenderColor{
                    .red = @as(u16, @truncate(rgb >> 16)) << 8,
                    .green = @as(u16, @truncate(rgb >> 8)) << 8,
                    .blue = @as(u16, @truncate(rgb)) << 8,
                    .alpha = 0xffff,
                };
                return color_alloc_value(
                    conn,
                    visual,
                    get_colormap(conn),
                    &xcolor,
                    color,
                );
            } else |_| {
                return false;
            }
        }

        return color_alloc_name(
            conn,
            get_colormap(conn),
            name,
            color,
        );
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
        const color = dc.col[@intCast(x)].pixel;
        r.* = @intCast(color.red >> 8);
        g.* = @intCast(color.green >> 8);
        b.* = @intCast(color.blue >> 8);
    }

    pub fn run(self: *Self) !void {
        const xfd = c.xcb_get_file_descriptor(self.connection);
        var fds: [2]std.posix.pollfd = .{
            .{ .fd = xfd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.pty.master, .events = std.posix.POLL.IN, .revents = 0 },
        };
        var buffer: [8024]u8 = undefined;

        while (true) {
            _ = std.posix.poll(&fds, -1) catch |err| {
                std.log.err("poll error: {}", .{err});
                return err;
            };

            if (fds[0].revents & std.posix.POLL.IN != 0) {
                while (true) {
                    const event = c.xcb_poll_for_event(self.connection) orelse break;
                    defer std.c.free(event);
                    try self.handleEvent(event);
                }
            }

            if (fds[1].revents & std.posix.POLL.IN != 0) {
                const n = posix.read(self.pty.master, &buffer) catch |err| {
                    std.log.err("read error from pty: {}", .{err});
                    continue;
                };
                if (n > 0) {
                    // Process PTY output
                    for (buffer[0..n]) |char| {
                        if (char == '\n') {
                            self.term.cursor.pos.x = 0;
                            self.term.cursor.pos.y += 1;
                            if (self.term.cursor.pos.y >= self.term.size_grid.rows) {
                                self.term.cursor.pos.y = self.term.size_grid.rows - 1;
                                util.move([240]Glyph, self.term.line[0 .. self.term.size_grid.rows - 1], self.term.line[1..self.term.size_grid.rows]);
                                @memset(&self.term.line[self.term.size_grid.rows - 1], Glyph{
                                    .u = ' ',
                                    .fg_index = c.defaultfg,
                                    .bg_index = c.defaultbg,
                                    .mode = GLyphMode.initEmpty(),
                                });
                            }
                            self.term.dirty.set(self.term.cursor.pos.y);
                        } else if (char >= 32 and char <= 126) {
                            if (self.term.cursor.pos.x < self.term.size_grid.cols and self.term.cursor.pos.y < self.term.size_grid.rows) {
                                self.term.line[self.term.cursor.pos.y][self.term.cursor.pos.x] = Glyph{
                                    .u = char,
                                    .fg_index = c.defaultfg,
                                    .bg_index = c.defaultbg,
                                    .mode = GLyphMode.initEmpty(),
                                };
                                self.term.cursor.pos.x += 1;
                                if (self.term.cursor.pos.x >= self.term.size_grid.cols) {
                                    self.term.cursor.pos.x = 0;
                                    self.term.cursor.pos.y += 1;
                                    if (self.term.cursor.pos.y >= self.term.size_grid.rows) {
                                        self.term.cursor.pos.y = self.term.size_grid.rows - 1;
                                        util.move([240]Glyph, self.term.line[0 .. self.term.size_grid.rows - 1], self.term.line[1..self.term.size_grid.rows]);
                                        @memset(&self.term.line[self.term.size_grid.rows - 1], Glyph{
                                            .u = ' ',
                                            .fg_index = c.defaultfg,
                                            .bg_index = c.defaultbg,
                                            .mode = GLyphMode.initEmpty(),
                                        });
                                    }
                                }
                                self.term.dirty.set(self.term.cursor.pos.y);
                            }
                        }
                    }
                    try self.redraw();
                } else if (n == 0) {
                    break;
                }
            }
        }
    }
    pub fn xstartdraw(self: *Self) bool {
        return self.win.mode.isSet(.MODE_VISIBLE);
    }

    pub fn redraw2(self: *Self) !void {
        const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        const text = font.UtfHolder{ .str = &[_]u32{ 'H', 'e', 'l', 'l', 'o' }, .length = 5 };
        const text_color = c.xcb_render_color_t{ .red = 0xFFFF, .green = 0xFFFF, .blue = 0xFFFF, .alpha = 0xFFFF };
        const bg_color = c.xcb_render_color_t{ .red = 0x9090, .green = 0x9090, .blue = 0x9090, .alpha = 0xFFFF };
        const pmap = try font.createTextPixmap(
            self.connection,
            &self.dc.font.face,
            text,
            text_color,
            bg_color,
            self.dc.font.face.pattern,
            self.visual,
            self.dc.gc,
            self.pixmap,
        );
        defer _ = c.xcb_free_pixmap(self.connection, pmap);

        // const sizes = font.get_drawable_size(self.connection, self.pixmap);
        _ = c.xcb_copy_area(
            self.connection,
            pmap,
            get_main_window(self.connection),
            self.dc.gc,
            0,
            0,
            borderpx,
            borderpx,
            self.win.win_size.width,
            self.win.win_size.height,
        );
        _ = c.xcb_flush(self.connection);
    }

    fn handleEvent(self: *Self, event: *c.xcb_generic_event_t) !void {
        const event_type = event.response_type & ~@as(u8, 0x80);
        switch (event_type) {
            c.XCB_EXPOSE => {
                const expose_event = @as(*c.xcb_expose_event_t, @ptrCast(event));
                if (expose_event.window == get_main_window(self.connection)) {
                    self.term.dirty.setRangeValue(.{ .start = 0, .end = self.term.size_grid.rows }, true);
                    try self.redraw();
                }
            },
            c.XCB_KEY_PRESS => {
                const key_event = @as(*c.xcb_key_press_event_t, @ptrCast(event));
                if (key_event.event == get_main_window(self.connection)) {
                    const keysym = key_event.detail;
                    if (keysym >= 32 and keysym <= 126) {
                        const char = @as(u8, @intCast(keysym));
                        const x = self.term.cursor.pos.x;
                        const y = self.term.cursor.pos.y;
                        if (x < self.term.size_grid.cols and y < self.term.size_grid.rows) {
                            self.term.line[y][x] = Glyph{
                                .u = char,
                                .fg_index = c.defaultfg,
                                .bg_index = c.defaultbg,
                                .mode = GLyphMode.initEmpty(),
                            };
                            self.term.cursor.pos.x += 1;
                            if (self.term.cursor.pos.x >= self.term.size_grid.cols) {
                                self.term.cursor.pos.x = 0;
                                self.term.cursor.pos.y += 1;
                                if (self.term.cursor.pos.y >= self.term.size_grid.rows) {
                                    self.term.cursor.pos.y = self.term.size_grid.rows - 1;
                                    // Optionally scroll up
                                    util.move([240]Glyph, self.term.line[0 .. self.term.size_grid.rows - 1], self.term.line[1..self.term.size_grid.rows]);
                                    @memset(&self.term.line[self.term.size_grid.rows - 1], Glyph{
                                        .u = ' ',
                                        .fg_index = c.defaultfg,
                                        .bg_index = c.defaultbg,
                                        .mode = GLyphMode.initEmpty(),
                                    });
                                }
                            }
                            self.term.dirty.set(y);
                            try self.redraw();
                        }
                        _ = posix.write(self.pty.master, &[_]u8{char}) catch {};
                    }
                }
            },
            c.XCB_CONFIGURE_NOTIFY => {
                const config_event = @as(*c.xcb_configure_notify_event_t, @ptrCast(event));
                if (config_event.window == get_main_window(self.connection)) {
                    const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
                    const effective_width = config_event.width - 2 * borderpx;
                    const effective_height = config_event.height - 2 * borderpx;

                    const new_size = justty.winsize{
                        .ws_row = @intCast(@max(2, @divTrunc(effective_height, @as(u16, @intCast(self.dc.font.size.height))))),
                        .ws_col = @intCast(@max(2, @divTrunc(effective_width, @as(u16, @intCast(self.dc.font.size.width))))),
                        .ws_xpixel = 0,
                        .ws_ypixel = 0,
                    };
                    try self.pty.resize(new_size);
                    try self.term.resize(new_size.ws_col, new_size.ws_row);
                    self.win.win_size.width = config_event.width;
                    self.win.win_size.height = config_event.height;
                    // Recreate pixmap with new size
                    _ = c.xcb_free_pixmap(self.connection, self.pixmap);
                    self.pixmap = c.xcb_generate_id(self.connection);
                    _ = c.xcb_create_pixmap(
                        self.connection,
                        self.visual.visual_depth,
                        self.pixmap,
                        get_main_window(self.connection),
                        self.win.win_size.width,
                        self.win.win_size.height,
                    );
                    try self.redraw();
                }
            },
            else => {},
        }
    }

    fn renderTextGroup(self: *Self, text: []const u32, mode: GLyphMode, fg_index: u9, bg_index: u9, px: u16, py: u16) !void {
        _ = mode;
        _ = fg_index;
        const text_len: u32 = @intCast(text.len);
        // var fg_color = self.dc.col[fg_index].color;
        var bg_color = self.dc.col[bg_index].color;
        // if (mode.isSet(.ATTR_REVERSE)) {
        //     // const temp = fg_color;
        //     // fg_color = bg_color;
        //     bg_color = temp;
        // }

        var text_color: c.xcb_render_color_t = undefined;
        text_color.red = 0x4242;
        text_color.green = 0x4242;
        text_color.blue = 0x4242;
        text_color.alpha = 0xFFFF;

        const utf_holder = font.UtfHolder{ .str = text.ptr, .length = text_len };
        const text_pixmap = try font.createTextPixmap(
            self.connection,
            utf_holder,
            // fg_color.cval().*,
            text_color,
            bg_color.cval().*,
            self.xrender_font.face.pattern,
            self.visual,
            self.dc.gc,
            self.pixmap,
        );
        defer _ = c.xcb_free_pixmap(self.connection, text_pixmap);

        _ = c.xcb_copy_area(
            self.connection,
            text_pixmap,
            self.pixmap,
            self.dc.gc,
            0,
            0,
            @intCast(px),
            @intCast(py),
            @intCast(self.dc.font.size.width * text_len),
            @intCast(self.dc.font.size.height),
        );
    }

    // inline fn redraw(self: *Self) !void {
    //     var fg_color = self.dc.col[c.defaultfg].color;
    //     // var bg_color = self.dc.col[c.defaultbg].color;
    //     // try self.drawSimpleText(10, 20, "hello");

    //     _ = try self.dc.font.face.drawText(
    //         get_main_window(self.connection),
    //         0,
    //         @intCast(self.win.char_size.height - @as(u16, @intCast(self.dc.font.ascent))),

    //         &[_]u32{ 'H', 'e', 'l', 'l', 'o' },
    //         fg_color.cval().*,
    //         self.visual.visual_depth,
    //     );
    //     const mask = c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
    //     const values = [_]u32{
    //         0xFF000 | 0xff000000,
    //         0,
    //     };
    //     _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values);

    //     const clear_rect = c.xcb_rectangle_t{
    //         // .x = try safeLongToI16(advance.x),
    //         // .y = try safeLongToI16(advance.y),
    //         .x = 50 - @as(i16, @intCast(self.dc.font.ascent)),
    //         .y = 60 - @as(i16, @intCast(self.dc.font.ascent)),

    //         .width = self.win.win_size.width,
    //         .height = self.win.win_size.height,
    //     };
    //     _ = c.xcb_poly_fill_rectangle(
    //         self.connection,
    //         self.pixmap,
    //         self.dc.gc,
    //         1,
    //         &clear_rect,
    //     );
    //     // Copy the pixmap to the window
    //     // _ = c.xcb_copy_area(
    //     //     self.connection,
    //     //     self.pixmap,
    //     //     get_main_window(self.connection),
    //     //     self.dc.gc,
    //     //     0,
    //     //     0,
    //     //     0,
    //     //     0,
    //     //     self.win.win_size.width,
    //     //     self.win.win_size.height,
    //     // );

    //     _ = c.xcb_flush(self.connection);
    // }
    inline fn redraw(self: *XlibTerminal) !void {
        // Clear the entire pixmap
        const clear_rect = c.xcb_rectangle_t{
            .x = 0,
            .y = 0,
            .width = self.win.win_size.width,
            .height = self.win.win_size.height,
        };
        const mask = c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;
        const values = [_]u32{ self.dc.col[c.defaultbg].pixel | 0xff000000, 0 };
        _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values);
        _ = c.xcb_poly_fill_rectangle(
            self.connection,
            self.pixmap,
            self.dc.gc,
            1,
            &clear_rect,
        );

        // Redraw all lines (dirty or not) to ensure no text is lost
        for (self.term.line[0..self.term.size_grid.rows], 0..) |row, y| {
            try self.xdrawglyphfontspecs(row[0..self.term.size_grid.cols], 0, @intCast(y), self.term.size_grid.cols);
        }

        // Clear dirty flags
        self.term.dirty = DirtySet.initEmpty();

        // Copy pixmap to window
        _ = c.xcb_copy_area(
            self.connection,
            self.pixmap,
            get_main_window(self.connection),
            self.dc.gc,
            0,
            0,
            0,
            0,
            self.win.win_size.width,
            self.win.win_size.height,
        );

        _ = c.xcb_flush(self.connection);
    }
    pub fn deinit(self: *Self) void {
        self.pty.deinit();
        self.dc.font.face.deinit();
        _ = c.xcb_free_gc(self.connection, self.dc.gc);
        _ = c.xcb_free_pixmap(self.connection, self.pixmap);
        _ = c.xcb_destroy_window(self.connection, get_main_window(self.connection)); // Destroy main window
        _ = c.xcb_disconnect(self.connection);
    }
};
