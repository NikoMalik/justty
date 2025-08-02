const std = @import("std");
const c = @import("c.zig");
const posix = std.posix;
const justty = @import("justty.zig");
// const font = @import("font.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const data_structs = @import("datastructs.zig");
const assert = std.debug.assert;
const unicode = std.unicode;
const Keysym = @import("keysym.zig");
const escapes = @import("escapes.zig");
// const font = @import("xcb_font.zig");
const font = @import("fnt.zig");
pub const vtiden: []const u8 = "\x1B[?6c"; // VT102 identification string
pub const ascii_printable =
    \\ !\"#$%&'()*+,-./0123456789:;<=>?
    \\ @ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_
    \\ `abcdefghijklmnopqrstuvwxyz{|}~
;
const Buf = @import("pixbuf.zig");
const signal = @import("signal.zig");

const utf_size = 4;
const esc_buf_size = 128 * utf_size;
const esc_arg_size = 16;
const str_buf_size = esc_buf_size;
const str_arg_size = esc_arg_size;

//================================HELP_FUNCTIONS===================================//

pub inline fn ATTRCMP(a: Glyph, b: Glyph) bool {
    return a.mode.eql(b.mode) and
        a.fg_index == b.fg_index and
        a.bg_index == b.bg_index;
}

inline fn countWidth(comptime T: type, comptime border_px: T, comptime cols_u16: T, cw: T) !u16 {
    return std.math.add(
        T,
        try std.math.mul(T, 2, border_px),
        try std.math.mul(T, cols_u16, cw),
    );
}

inline fn countHeight(comptime T: type, comptime border_px: T, comptime rows_16: T, ch: T) !u16 {
    return std.math.add(
        T,
        try std.math.mul(T, 2, border_px),
        try std.math.mul(T, rows_16, ch),
    );
}

pub inline fn TIMEDIFF(t1: c.struct_timespec, t2: c.struct_timespec) c_long {
    return (t1.tv_sec - t2.tv_sec) * 1000 + @divTrunc(t1.tv_nsec - t2.tv_nsec, 1_000_000);
}

inline fn DEFAULT(comptime T: type, value: T, def: T) T {
    return if (value != 0) value else def;
}

// =========================== Enumerations and Bitsets ===========================

// Attributes for a single character (Glyph)
const Glyph_flags = enum(u4) {
    ATTR_NULL = 0, // No attributes
    ATTR_BOLD = 1, // Bold text
    ATTR_FAINT = 2, // Faint text
    ATTR_ITALIC = 3, // Italic text
    ATTR_UNDERLINE = 4, // Underlined text
    ATTR_BLINK = 5, // Blinking text
    ATTR_REVERSE = 6, // Reverse colors
    ATTR_INVISIBLE = 7, // Invisible text
    ATTR_STRUCK = 8, // Strikethrough text
    ATTR_WRAP = 9, // Line wrap
    ATTR_WIDE = 10, // Wide character
    ATTR_WDUMMY = 11, // Dummy wide character
    ATTR_BOLD_FAINT = 12, // Bold and faint combined
};

// Bitset for Glyph attributes
const GLyphMode = data_structs.IntegerBitSet(Glyph_flags);

// Terminal mode flags
const TermModeFlags = enum(u3) {
    MODE_WRAP = 0, // Enable line wrapping
    MODE_INSERT = 1, // Insert mode
    MODE_ALTSCREEN = 2, // Use alternate screen buffer
    MODE_CRLF = 3, // Carriage return + line feed
    MODE_ECHO = 4, // Echo input to screen
    MODE_PRINT = 5, // Print mode
    MODE_UTF8 = 6, // UTF-8 encoding
};

const Esc_flags = enum(u3) {
    ESC_START = 0,
    ESC_CSI = 2,
    ESC_STR = 3, // DCS, OSC, PM, APC */
    ESC_ALTCHARSET = 4,
    ESC_STR_END = 5, // a final string was encountered */
    ESC_TEST = 6, // Enter in test mode */
    ESC_UTF8 = 7,
};

const CursorFlags = enum(u3) {
    CURSOR_DEFAULT = 0,
    CURSOR_WRAPNEXT = 1,
    CURSOR_ORIGIN = 2,
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

const WinMode = data_structs.IntegerBitSet(WinModeFlags);

const CursorMode = data_structs.IntegerBitSet(CursorFlags);

const EscMode = data_structs.IntegerBitSet(Esc_flags);

// Bitset for terminal modes
const TermMode = data_structs.IntegerBitSet(TermModeFlags);
// const elements = enum(u8) {
//     COPY_FROM_PARENT = c.XCB_COPY_FROM_PARENT,
// };

pub const masks = union(enum(u32)) {
    pub const WINDOW_WM: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_BORDER_PIXEL | c.XCB_CW_BIT_GRAVITY | c.XCB_CW_COLORMAP;
    pub const CHILD_EVENT_MASK: u32 = c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE | c.XCB_EVENT_MASK_BUTTON_MOTION;

    pub const WINDOW_CURSOR: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK | c.XCB_CW_CURSOR;
};

const Key = packed struct(u64) {
    key_sym: c.xcb_keysym_t,
    mode: u32,
};

/// CSI Escape sequence structs
/// `ESC '[' [[ [<priv>] <arg> [;]] <mode> [<mode>]]`
/// (Control Sequence Introducers)
const CSIEscape = struct {
    buf: [esc_buf_size]u8,
    esc_len: usize,
    priv: u8,
    params: [esc_arg_size]u32,
    narg: usize,
    mode: [2]u8,

    const Self = @This();
    fn reset(self: *Self, xterm: *XlibTerminal) void {
        xterm.term.esc_mode = EscMode.initEmpty();
        self.esc_len = 0;
        self.narg = 0;
        self.priv = 0;
        self.mode = [_]u8{ 0, 0 };
    }

    pub fn parse_esc(self: *Self, xterm: *XlibTerminal, data: []const u8) !void {
        for (data) |byte| {
            if (byte == '\n') {
                xterm.term.cursor.pos.addX(0);
                if (xterm.term.cursor.pos.getY().? < xterm.term.window.tty_grid.getRows().? - 1) {
                    xterm.term.cursor.pos.data.position.y += 1;
                } else {
                    xterm.scrollUp(1);
                }
                xterm.term.set_dirt(@intCast(xterm.term.cursor.pos.getY().?), @intCast(xterm.term.cursor.pos.getY().?));
                continue;
            }

            if (self.esc_len >= self.buf.len) {
                std.log.warn("Escape sequence buffer overflow: {x}", .{self.buf[0..self.esc_len]});
                xterm.term.esc_mode = EscMode.initEmpty();
                self.esc_len = 0;
                continue;
            }

            self.buf[self.esc_len] = byte;
            self.esc_len += 1;

            if (self.esc_len == 1 and byte == 0x1B) {
                xterm.term.esc_mode.set(.ESC_START);
                continue;
            }

            if (xterm.term.esc_mode.isSet(.ESC_START) and self.esc_len >= 2) {
                switch (self.buf[1]) {
                    '[' => xterm.term.esc_mode.set(.ESC_CSI), // csi handle
                    '(', ')' => xterm.term.esc_mode.set(.ESC_ALTCHARSET),
                    ']', 'P', '^', '@' => xterm.term.esc_mode.set(.ESC_STR),
                    else => {
                        xterm.term.esc_mode = EscMode.initEmpty();
                        self.esc_len = 0;
                        continue;
                    },
                }
            }

            if (xterm.term.esc_mode.isSet(.ESC_CSI) and self.esc_len >= 2) {
                const final_char_range_start: u8 = '@';
                const final_char_range_end: u8 = '~';
                if (self.esc_len > 2 and byte >= final_char_range_start and byte <= final_char_range_end) {
                    std.log.debug("Parsed CSI: mode={c}, params={any}, narg={d}, priv={d}", .{
                        self.mode[0],
                        self.params[0..self.narg],
                        self.narg,
                        self.priv,
                    });
                    self.narg = 0;
                    self.priv = if (self.esc_len > 2 and self.buf[2] == '?') 1 else 0;
                    self.mode[0] = byte;
                    self.mode[1] = 0;

                    // Parse parameters
                    if (self.esc_len > 3) {
                        const param_str = self.buf[2 + self.priv .. self.esc_len - 1];
                        var start: usize = 0;
                        while (start < param_str.len) {
                            const remaining_len = @min(param_str.len - start, 16);
                            const chunk = param_str[start .. start + remaining_len];
                            var chunk_vec: @Vector(16, u8) = undefined;
                            for (chunk, 0..) |cc, i| {
                                chunk_vec[i] = cc;
                            }

                            const semicolon_vec: @Vector(16, u8) = @splat(';');
                            const comparison = chunk_vec == semicolon_vec;
                            const found_semicolon = @reduce(.Or, comparison);

                            var end: usize = start + remaining_len;
                            if (found_semicolon) {
                                for (chunk, 0..) |cc, i| {
                                    if (cc == ';') {
                                        end = start + i;
                                        break;
                                    }
                                }
                            }

                            if (start < end and self.narg < self.params.len) {
                                const num_str = param_str[start..end];
                                self.params[self.narg] = std.fmt.parseInt(u32, num_str, 10) catch 0;
                                self.narg += 1;
                            }
                            start = end + 1;
                        }
                    } else {
                        self.params[self.narg] = 0;
                        self.narg += 1;
                    }

                    try xterm.csihandle(self); // Process the CSI sequence
                    self.reset(xterm);
                    // xterm.term.esc_mode = EscMode.initEmpty();
                    // self.esc_len = 0;
                }
            } else if (xterm.term.esc_mode.isSet(.ESC_STR) or xterm.term.esc_mode.isSet(.ESC_ALTCHARSET)) {
                if (byte == 0x07 or byte == 0x1B) {
                    xterm.term.esc_mode = EscMode.initEmpty();
                    self.esc_len = 0;
                }
            } else if (self.esc_len > 32) {
                std.log.warn("Incomplete escape sequence, resetting: {x}", .{self.buf[0..self.esc_len]});
                xterm.term.esc_mode = EscMode.initEmpty();
                self.esc_len = 0;
            }
        }
    }
};

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
    ///*tty width and height in columns and rows */
    tty_grid: rect = rect.initGrid(0, 0),
    //*window width and height */
    win_size: rect = rect.initSize(0, 0),
    // /*char height and width */
    char_size: rect = rect.initSize(0, 0),
    cursor: u16 = c.CURSORSHAPE,
};

const Font = struct {
    face: font.RenderFont,
    size: rect = rect.initSize(0, 0),
    ascent: u32,
};
// Drawing Context
const DC = struct {
    col: [260]Color = undefined, // len: usize,
    font: Font,
    gc: c.xcb_gcontext_t,
};

//Represents a single “cell” of the screen with the symbol and its attributes:
// grid based interfaces
pub const Glyph = struct {
    mode: GLyphMode, // flags BOLD,ITALIC and more
    u: u32 = 0, //unicode  char
    fg_index: u9 = @as(u9, @intCast(c.defaultfg)), //foreground
    bg_index: u9 = @as(u9, @intCast(c.defaultbg)), //background

    pub fn initEmpty() Glyph {
        return .{
            .u = ' ',
            .fg_index = c.defaultfg,
            .bg_index = c.defaultbg,
            .mode = GLyphMode.initEmpty(),
        };
    }
};

const DirtySet = std.bit_set.ArrayBitSet(u16, c.MAX_ROWS);

pub const Term = struct {
    mode: TermMode, // Terminal modes
    /// Allocator
    allocator: Allocator,
    //(e.g., line auto-transfer, alternate screen, UTF-8).
    dirty: DirtySet, //Bitmask to keep track of “dirty” rows that need to be redrawn.
    line: [c.MAX_ROWS][c.MAX_COLS]Glyph, // Array of strings with fixed size MAX_ROWS
    alt: [c.MAX_ROWS][c.MAX_COLS]Glyph, // alt array(for example vim,htop) of strings with fixes size MAX_ROWS
    parser: escapes.Parser,
    //For an 80x24 character terminal with a Glyph size of 16 bytes, one screen takes ~30 KB.
    //Two screens - ~60 KB. can we use union for 60kb? mb not
    // cols,rows
    window: TermWindow,
    cursor: TCursor, //cursor
    tabs: [c.MAX_COLS]u8,

    ocx: u16 = 0, // Previous cursor position X
    ocy: u16 = 0, // Previous cursor position Y
    top: u16 = 0, // Upper scroll limit
    bot: u16 = 0, // Lower scroll limit
    lastc: u32 = 0, //stores the last typed character in the terminal. It is required to process certain escape sequences, such as CSI REP
    // esc: u16 = 0, // Status of ESC sequences
    charset: u16 = 0, // Current encoding
    icharset: u16 = 0, // Encoding index
    trantbl: [4]u8, // /* charset table translation */
    cursor_visible: bool, // Cursor visibility

    pub fn init(allocator: Allocator, window: TermWindow) !Term {
        var term: Term = .{
            .window = window,
            .mode = TermMode.initEmpty(),
            .allocator = allocator,
            .dirty = DirtySet.initEmpty(),
            .line = undefined,
            .alt = undefined,
            .cursor = TCursor{
                .attr = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() },
                .state = CursorMode.initEmpty(),
            },
            .tabs = undefined,
            .parser = escapes.Parser.init(allocator),
            .ocx = 0,
            .ocy = 0,
            .top = 0,
            .bot = window.tty_grid.getRows().? - 1,
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
        term.mode.set(.MODE_WRAP);
        return term;
    }

    pub fn reset(self: *Term) void {
        self.parser.reset();
        self.mode = TermMode.initEmpty();
        self.mode.set(.MODE_WRAP);
        self.cursor = TCursor{
            .attr = Glyph{ .u = ' ', .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() },
            .state = CursorMode.initEmpty(),
        };
        self.ocx = 0;
        self.ocy = 0;
        self.top = 0;
        self.bot = self.window.tty_grid.getRows().? - 1;
        self.lastc = 0;
        self.charset = 0;
        self.icharset = 0;
        self.trantbl = [_]u8{0} ** 4;
        self.cursor_visible = true;
        @memset(&self.line, [_]Glyph{Glyph.initEmpty()} ** c.MAX_COLS);
        @memset(&self.alt, [_]Glyph{Glyph.initEmpty()} ** c.MAX_COLS);
        self.fulldirt();
    }

    // NOTE: Inserts n empty characters at the current cursor position, shifting existing characters to the right.
    pub inline fn csi_ich(self: *Term, params: []u32) !void { // Insert Characters
        const n = DEFAULT(u32, params[0], 1);
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const cursor_x = self.cursor.pos.getX().?; // i16
        const cols: i16 = @intCast(self.window.tty_grid.getCols().?); // u16
        const row = self.cursor.pos.getY().?; // i16

        // has some space?
        if (cursor_x >= cols) return;

        // count symbols to move
        const chars_to_shift = try std.math.sub(i16, @intCast(cols), @intCast(cursor_x));
        const insert_count: i16 = @min(@as(i16, @intCast(n)), chars_to_shift);

        // move to right
        if (chars_to_shift > insert_count) {
            util.move(
                Glyph,
                screen[@intCast(row)][@intCast(cursor_x + insert_count)..@intCast(cols)],
                screen[@intCast(row)][@intCast(cursor_x)..@intCast(cols - insert_count)],
            );
        }

        //
        // default (cursor_x=2):
        // [A][B][C][D][E][F][G][H][I][J]
        //        ^
        //
        // add 2 zero chars (n=2):
        // - util.move moves [C][D][E][F][G][H] in [4..10]
        // - @memset set [2..4] zero Glyph
        //
        // result:
        // [A][B][ ][ ][C][D][E][F][G][H]
        //        ^

        // ostatok with zero glyphs
        @memset(screen[@intCast(row)][@intCast(cursor_x)..@intCast(cursor_x + insert_count)], Glyph.initEmpty());

        self.set_dirt(@intCast(row), @intCast(row));
    }

    // NOTE: Deletes n characters starting from the current cursor position, shifting the remaining characters to the left.
    pub inline fn csi_dch(self: *Term, params: []u32) void { // Delete Characters
        const n = DEFAULT(u32, params[0], 1);
        self.tdeletechar(n);
    }

    // NOTE: Moves the cursor up n lines.
    pub inline fn csi_cuu(self: *Term, params: []u32) !void {
        const n = DEFAULT(u32, params[0], 1);
        const old_y = self.cursor.pos.getY().?;
        const new_y = if (old_y > n)
            try std.math.sub(i16, old_y, @intCast(n))
        else
            0;
        self.cursor.pos.addY(new_y);
        self.set_dirt(@intCast(old_y), @intCast(new_y));
    }
    // NOTE: Moves the cursor to the left by n positions.
    pub inline fn csi_cub(self: *Term, params: []u32) !void {
        const n = DEFAULT(u32, params[0], 1);
        const old_x = self.cursor.pos.getX().?;
        const new_x = if (old_x > n)
            try std.math.sub(i16, old_x, @intCast(n))
        else
            0;
        self.cursor.pos.addX(new_x);
        self.set_dirt(@intCast(self.cursor.pos.getY().?), @intCast(self.cursor.pos.getY().?));
    }

    pub inline fn moveCursor(self: *Term, dx: i16, dy: i16) void {
        var pos_vec: @Vector(2, i16) = .{ self.cursor.pos.getX().?, self.cursor.pos.getY().? };
        const delta_vec: @Vector(2, i16) = .{ dx, dy };
        pos_vec += delta_vec;
        self.cursor.pos.addPosition(pos_vec[0], pos_vec[1]);
    }

    inline fn computeScreenPosition(self: *Term, char_width: u16, char_height: u16) !struct { px: u16, py: u16 } {
        const pos_vec: @Vector(2, u16) = .{ @intCast(self.cursor.pos.getX().?), @intCast(self.cursor.pos.getY().?) };
        const size_vec: @Vector(2, u16) = .{ char_width, char_height };
        const screen_vec = pos_vec * size_vec;
        return .{ .px = screen_vec[0], .py = screen_vec[1] };
    }

    // NOTE: Moves the cursor down n lines.
    pub inline fn csi_cud(self: *Term, params: []u32) void {
        const n = DEFAULT(u32, params[0], 1);
        const old_y = self.cursor.pos.getY().?;
        const new_y = @min(
            old_y + @as(i16, @intCast(n)),
            @as(i16, @intCast(self.window.tty_grid.getRows().? - 1)),
        );
        self.cursor.pos.addY(new_y);
        self.set_dirt(@intCast(old_y), @intCast(new_y));
    }
    // NOTE: Processes Media Control commands. (Media Control)
    pub inline fn csi_mc(self: *Term, params: []u32, xterm: *XlibTerminal) void {
        switch (params[0]) {
            0 => xterm.tdump(),
            1 => xterm.tdumpline(self.cursor.pos.getY().?),
            2 => xterm.tdumpsel(),
            4 => self.mode.unset(.MODE_PRINT),
            5 => self.mode.set(.MODE_PRINT),
            else => std.log.warn("Unknown MC parameter: {}", .{params[0]}),
        }
    }
    // NOTE: ask for questions about DEVICE ATTRIBUTES
    pub inline fn csi_da(_: *Term, params: []u32, xterm: *XlibTerminal) void {
        if (params[0] == 0) {
            xterm.ttywrite(vtiden, vtiden.len, 0);
        }
    }
    // NOTE:moves the cursor right n lines
    pub inline fn csi_cuf(self: *Term, params: []u32) void { // Cursor Forward
        const n = DEFAULT(u32, params[0], 1);
        const new_x = @min(self.cursor.pos.getX().? + @as(i16, @intCast(n)), @as(i16, @intCast(self.window.tty_grid.getCols().? - 1)));
        self.cursor.pos.addX(new_x);
        self.set_dirt(@intCast(self.cursor.pos.getY().?), @intCast(self.cursor.pos.getY().?));
    }

    // NOTE: Moves the cursor to the beginning of the next line (or n lines below).
    pub inline fn csi_cnl(self: *Term, params: []u32) void {
        const n = DEFAULT(u32, params[0], 1);
        const old_y = self.cursor.pos.getY().?;
        self.cursor.pos.addX(0);
        const new_y = @min(old_y + @as(i16, @intCast(n)), @as(i16, @intCast(self.window.tty_grid.getRows().? - 1)));
        self.cursor.pos.addY(new_y);
        self.set_dirt(@intCast(old_y), @intCast(new_y));
    }
    // NOTE: Moves the cursor to the beginning of the previous line (or n lines above).
    pub inline fn csi_cpl(self: *Term, params: []u32) void {
        const n = DEFAULT(u32, params[0], 1);
        const old_y = self.cursor.pos.getY().?;
        self.cursor.pos.addX(0);
        const new_y = if (old_y > n) old_y - @as(i16, @intCast(n)) else 0;
        self.cursor.pos.addY(new_y);
        self.set_dirt(@intCast(new_y), @intCast(old_y));
    }
    // NOTE: Controls the tabulation setting (Tabulation Clear).
    pub inline fn csi_tbc(self: *Term, params: []u32) void {
        switch (params[0]) {
            0 => self.tabs[@intCast(self.cursor.pos.getX().?)] = 0,
            3 => @memset(&self.tabs, 0),
            else => std.log.warn("Unknown TBC parameter: {}", .{params[0]}),
        }
    }
    // NOTE: Moves the cursor to the absolute position on the current line.
    pub inline fn csi_cha(self: *Term, params: []u32) void {
        const n = DEFAULT(u32, params[0], 1);
        const new_x = @min(@as(i16, @intCast(n - 1)), @as(i16, @intCast(self.window.tty_grid.getCols().? - 1)));
        self.cursor.pos.addX(new_x);
        self.set_dirt(@intCast(self.cursor.pos.getY().?), @intCast(self.cursor.pos.getY().?));
    }

    // NOTE: Moves the cursor to the specified position (row, column).
    pub inline fn csi_cup(self: *Term, params: []u32) void { // Cursor Position
        const row = DEFAULT(u32, params[0], 1);
        const col = DEFAULT(u32, params[1], 1);
        const new_y = @min(@as(i16, @intCast(row - 1)), @as(i16, @intCast(self.window.tty_grid.getRows().? - 1)));
        const new_x = @min(@as(i16, @intCast(col - 1)), @as(i16, @intCast(self.window.tty_grid.getCols().? - 1)));
        const old_y = self.cursor.pos.getY().?;
        self.cursor.pos.addPosition(new_x, new_y);
        self.set_dirt(@intCast(old_y), @intCast(new_y));
    }
    // NOTE: Moves the cursor n tabs to the right.
    pub inline fn csi_cht(self: *Term, params: []u32) void { // Character Tabulation
        const n = DEFAULT(u32, params[0], 1);
        self.tputtab(@intCast(n));
    }

    // NOTE: Clears the screen or part of it depending on the parameter n.
    pub inline fn csi_ed(self: *Term, params: []u32) void { // Erase Display
        const n = params[0];
        const cols = self.window.tty_grid.getCols().? - 1;
        const rows = self.window.tty_grid.getRows().? - 1;
        switch (n) {
            0 => {
                self.tclearregion(self.cursor.pos.getX().?, self.cursor.pos.getY().?, @intCast(cols), self.cursor.pos.getY().?);
                if (self.cursor.pos.getY().? < rows) {
                    self.tclearregion(0, self.cursor.pos.getY().? + 1, @intCast(cols), @intCast(rows)); //TODO: MAKE COMPTIME TYPE WITHOUT INTCAST EVERYTIME
                }
            },
            1 => {
                if (self.cursor.pos.getY().? > 0) {
                    self.tclearregion(0, 0, @intCast(cols), self.cursor.pos.getY().? - 1);
                }
                self.tclearregion(0, self.cursor.pos.getY().?, self.cursor.pos.getX().?, self.cursor.pos.getY().?);
            },
            2 => {
                self.tclearregion(0, 0, @intCast(cols), @intCast(rows));
            },
            else => std.log.warn("Unknown ED parameter: {}", .{n}),
        }
    }

    // NOTE: Clears the string or part of it depending on the parameter n.
    pub inline fn csi_el(self: *Term, params: []u32) void {
        const n = DEFAULT(u32, params[0], 0);
        const y = self.cursor.pos.getY().?;
        const cols = self.window.tty_grid.getCols().? - 1;
        switch (n) {
            0 => self.tclearregion(self.cursor.pos.getX().?, y, @intCast(cols), y),
            1 => self.tclearregion(0, y, self.cursor.pos.getX().?, y),
            2 => self.tclearregion(0, y, @intCast(cols), y),
            else => std.log.warn("Unknown EL parameter: {}", .{n}),
        }
    }

    // NOTE: Scrolls up the screen by n lines.
    pub inline fn csi_su(self: *Term, params: []u32) void { // Pan Down / Scroll Up
        const n = DEFAULT(u32, params[0], 1);
        self.tscrollup(self.top, n);
    }

    // NOTE: Scrolls the screen down n lines.
    pub inline fn csi_sd(self: *Term, params: []u32) void { // Scroll Down
        const n = DEFAULT(u32, params[0], 1);
        self.tscrolldown(self.top, n);
    }
    // NOTE: Inserts n empty lines at the current cursor position.
    pub inline fn csi_il(self: *Term, params: []u32) void {
        const n = DEFAULT(u32, params[0], 1);
        self.tinsertblankline(n);
    }
    // NOTE: Resets the terminal modes.
    pub inline fn csi_rm(self: *Term, params: []u32, narg: usize, priv: u8, winmode: *WinMode) void { // Reset Mode
        self.tsetmode(priv, 0, params, narg, winmode);
    }

    // NOTE: Deletes n lines starting from the current cursor position.
    pub inline fn csi_dl(self: *Term, params: []u32) void { // Delete Line
        const n = DEFAULT(u32, params[0], 1);
        self.tdeleteline(n);
    }
    // NOTE: Clears n characters starting from the current cursor position.
    pub inline fn csi_ech(self: *Term, params: []u32) void { // Erase Characteres
        const n = DEFAULT(u32, params[0], 1);
        const end_x = @min(
            self.cursor.pos.getX().? + @as(i16, @intCast(n)) - 1,
            @as(i16, @intCast(self.window.tty_grid.getCols().? - 1)),
        );
        self.tclearregion(
            self.cursor.pos.getX().?,
            self.cursor.pos.getY().?,
            end_x,
            self.cursor.pos.getY().?,
        );
    }
    // NOTE: Moves the cursor n tabs to the left.
    pub inline fn csi_cbt(self: *Term, params: []u32) void { // Character Backwards Tabulation
        const n = DEFAULT(i16, @intCast(params[0]), 1);
        self.tputtab(-n);
    }
    // NOTE: Moves the cursor to the specified line (absolute position).
    pub inline fn csi_vpa(self: *Term, params: []u32) void {
        const n = DEFAULT(i16, @intCast(params[0]), 1);
        const new_y = @min(@as(i16, @intCast(n - 1)), @as(i16, @intCast(self.window.tty_grid.getRows().? - 1)));
        const old_y = self.cursor.pos.getY().?;
        self.cursor.pos.addY(new_y);
        self.set_dirt(@intCast(old_y), @intCast(new_y));
    }

    // NOTE: Set terminal nodes
    pub inline fn csi_sm(self: *Term, params: []u32, narg: usize, priv: u8, winmode: *WinMode) void {
        self.tsetmode(priv, 1, params, narg, winmode);
    }

    // NOTE: Sets character attributes (color, style, etc.).
    pub fn csi_sgr(self: *Term, params: []u32, narg: usize) void { // Select Graphic Rendition
        self.handle_sgr(params[0..narg]);
        self.set_dirt(@intCast(self.cursor.pos.getY().?), @intCast(self.cursor.pos.getX().?));
    }
    // NOTE: Responds to cursor or device status requests (Device Status Report).
    pub inline fn csi_dsr(self: *Term, params: []u32, xterm: *XlibTerminal) void {
        var buf: [40]u8 = undefined;
        switch (params[0]) {
            5 => xterm.ttywrite("\x1B[0n", 4, 0),
            6 => {
                const res = std.fmt.bufPrint(&buf, "\x1B[{d};{d}R", .{ self.cursor.pos.getY().? + 1, self.cursor.pos.getX().? + 1 }) catch return;
                xterm.ttywrite(res, res.len, 0);
            },
            else => std.log.warn("Unknown DSR parameter: {}", .{params[0]}),
        }
    }

    // NOTE: Sets the upper and lower scroll limits.
    pub fn csi_decstbm(self: *Term, params: []u32) void {
        const top = DEFAULT(u32, params[0], 1);
        const bot = DEFAULT(u32, params[1], self.window.tty_grid.getRows().?);
        self.tsetscroll(@as(u16, @intCast(top - 1)), @as(u16, @intCast(bot - 1)));
        self.tmoveto(0, 0);
    }
    // fn csi_decsc(self: *Term) void {
    //     self.tcursor(CURSOR_SAVE);
    // }

    // fn csi_decrc(self: *Term) void {
    //     self.tcursor(CURSOR_LOAD);
    // }

    // fn csi_decscusr(_: *Term, params: []u32, xterm: *XlibTerminal) bool {
    //     return xterm.xsetcursor(params[0]);
    // }
    //

    // NOTE: Inserts n empty characters on the current line, shifting the existing ones to the right.
    inline fn tinsertblank(self: *Term, n: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const cols = self.window.tty_grid.getCols().?;
        const dest = self.cursor.pos.getX().? + @as(i16, @intCast(n));
        if (dest >= cols) return;
        util.move(
            Glyph,
            screen[self.cursor.pos.getY().?][dest..cols],
            screen[self.cursor.pos.getY().?][self.cursor.pos.getX().? .. cols - @as(u16, @intCast(n))],
        );
        @memset(
            screen[self.cursor.pos.getY().?][self.cursor.pos.getX().?..dest],
            Glyph.initEmpty(),
        );
        self.set_dirt(self.cursor.pos.getY().?, self.cursor.pos.getY().?);
    }

    // NOTE: Moves the cursor to the specified coordinates (x, y).
    inline fn tmoveto(self: *Term, x: i16, y: i16) void {
        const cols: i16 = @intCast(self.window.tty_grid.getCols().?);
        const rows: i16 = @intCast(self.window.tty_grid.getRows().?);
        const new_x = std.math.clamp(x, 0, cols - 1);
        const new_y = std.math.clamp(y, 0, rows - 1);
        const old_y = self.cursor.pos.getY().?;
        self.cursor.pos.addPosition(new_x, new_y);
        self.set_dirt(@intCast(old_y), @intCast(new_y));
    }
    // NOTE: Clears the screen area from (x1, y1) to (x2, y2).
    inline fn tclearregion(self: *Term, x1: i16, y1: i16, x2: i16, y2: i16) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const cols: i16 = @intCast(self.window.tty_grid.getCols().?);
        const rows: i16 = @intCast(self.window.tty_grid.getRows().?);
        const max_x = std.math.clamp(x2, 0, cols - 1);
        const max_y = std.math.clamp(y2, 0, rows - 1);
        for (@max(y1, 0)..@intCast(max_y + 1)) |y| {
            @memset(screen[y][@max(x1, 0)..@intCast(max_x + 1)], Glyph.initEmpty());
            self.set_dirt(@intCast(y), @intCast(y));
        }
    }

    // NOTE: Moves the cursor to the next or previous tab position.
    pub inline fn tputtab(self: *Term, n: i16) void {
        const cols = self.window.tty_grid.getCols().?;
        var x = self.cursor.pos.getX().?;
        if (n > 0) {
            var count: u16 = @intCast(n);
            while (x < cols and count > 0) : (count -= 1) {
                x += 1;
                while (x < cols and self.tabs[@intCast(x)] == 0) x += 1;
            }
        } else if (n < 0) {
            var count: i16 = n;
            while (x > 0 and count < 0) : (count += 1) {
                x -= 1;
                while (x > 0 and self.tabs[@intCast(x)] == 0) x -= 1;
            }
        }
        self.cursor.pos.addX(@min(x, @as(i16, @intCast(cols - 1))));
        self.set_dirt(@intCast(self.cursor.pos.getY().?), @intCast(self.cursor.pos.getY().?));
    }

    // NOTE: Scrolls up the screen by n lines in the area from top to bottom.
    pub inline fn tscrollup(self: *Term, top: u16, n: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const rows = self.window.tty_grid.getRows().?;
        const shift = @min(n, @as(u32, rows - top));
        if (shift == 0) return;

        util.move(
            [c.MAX_COLS]Glyph,
            screen[top .. rows - shift],
            screen[top + shift .. rows],
        );

        for (rows - shift..rows) |y| {
            @memset(&screen[y], Glyph.initEmpty());
            self.set_dirt(@intCast(y), @intCast(y));
        }
        self.set_dirt(top, rows - 1);
    }

    // NOTE: Scrolls the screen down n lines in the area from top to bottom.
    pub inline fn tscrolldown(self: *Term, top: u16, n: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const rows = self.window.tty_grid.getRows().?;
        const shift = @min(n, @as(u32, rows - top));
        if (shift == 0) return;

        util.move(
            [c.MAX_COLS]Glyph,
            screen[top .. rows - shift],
            screen[top + shift .. rows],
        );

        for (top..top + shift) |y| {
            @memset(&screen[y], Glyph.initEmpty());
            self.set_dirt(@intCast(y), @intCast(y));
        }
        self.set_dirt(top, rows - 1);
    }

    // NOTE: Inserts n empty lines at the current cursor position, pushing the existing ones down.
    inline fn tinsertblankline(self: *Term, n: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const rows = self.window.tty_grid.getRows().?;
        const cursor_y = self.cursor.pos.getY().?;
        const shift = @min(n, @as(u32, @intCast(@as(i16, @intCast(rows)) - cursor_y))); // TODO:MAKE EVERYTHERE std..math.sub or std.math.add or comptime checks type
        if (shift == 0) return;

        util.move(
            [c.MAX_COLS]Glyph,
            screen[@as(usize, @intCast(cursor_y)) + shift .. rows],
            screen[@intCast(cursor_y) .. rows - shift],
        );

        for (@intCast(cursor_y)..@as(usize, @intCast(cursor_y)) + shift) |y| {
            @memset(&screen[y], Glyph.initEmpty());
            self.set_dirt(@intCast(y), @intCast(y));
        }
    }
    // NOTE: Sets the terminal or window modes depending on the parameters.
    inline fn tsetmode(
        self: *Term,
        priv: u8,
        set: u8,
        args: []u32,
        narg: usize,
        winmode: *WinMode,
    ) void {
        for (args[0..narg]) |arg| {
            if (priv != 0) {
                switch (arg) {
                    1 => winmode.setOrUnset(.MODE_APPCURSOR, set != 0),
                    12 => winmode.setOrUnset(.MODE_BLINK, set != 0),
                    25 => self.cursor_visible = (set != 0),
                    1049 => {
                        self.mode.setOrUnset(.MODE_ALTSCREEN, set != 0);
                        self.fulldirt();
                    },
                    else => std.log.debug("Unknown private mode: {}", .{arg}),
                }
            } else {
                switch (arg) {
                    4 => self.mode.setOrUnset(.MODE_WRAP, set != 0),
                    else => std.log.debug("Unknown mode: {}", .{arg}),
                }
            }
        }
    }
    // NOTE: Deletes n lines starting from the current cursor position, shifting the remaining ones upwards.
    inline fn tdeleteline(self: *Term, n: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const rows = @as(u32, self.window.tty_grid.getRows().?);
        const cursor_y = @as(u32, @intCast(self.cursor.pos.getY().?));
        const shift = @min(n, rows - cursor_y);
        if (shift == 0) return;

        util.move(
            [c.MAX_COLS]Glyph,
            screen[@intCast(cursor_y) .. rows - shift],
            screen[@as(usize, @intCast(cursor_y)) + shift .. rows],
        );

        for (rows - shift..rows) |y| {
            util.set(Glyph, &screen[y], Glyph.initEmpty());

            self.set_dirt(@intCast(y), @intCast(y));
        }
    }
    // NOTE: Deletes n characters on the current line, shifting the remaining characters to the left.
    inline fn tdeletechar(self: *Term, n: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;
        const cols = @as(u32, self.window.tty_grid.getCols().?);
        const x = @as(u32, @intCast(self.cursor.pos.getX().?));
        const y = @as(u32, @intCast(self.cursor.pos.getY().?));
        const shift = @min(n, cols - x);
        if (shift == 0) return;

        util.move(
            Glyph,
            screen[y][x .. cols - n],
            screen[y][x + n .. cols],
        );

        for (cols - n..cols) |xx| {
            screen[y][xx] = Glyph.initEmpty();
        }

        self.set_dirt(@intCast(y), @intCast(y));
    }

    // NOTE: Sets the scroll area from top to bot.
    inline fn tsetscroll(self: *Term, top: u16, bot: u16) void {
        const rows = self.window.tty_grid.getRows().?;
        self.top = @min(top, rows - 1);
        self.bot = @min(bot, rows - 1);
        if (self.top > self.bot) {
            self.top = 0;
            self.bot = rows - 1;
        }
    }
    // NOTE: Saves or loads the cursor position.
    pub fn tcursor(self: *Term, mode: enum { CURSOR_SAVE, CURSOR_LOAD }) void {
        if (mode == .CURSOR_SAVE) {
            self.ocx = @intCast(self.cursor.pos.getX().?);
            self.ocy = @intCast(self.cursor.pos.getY().?);
        } else {
            const old_y = self.cursor.pos.getY().?;
            self.cursor.pos.addPosition(@intCast(self.ocx), @intCast(self.ocy));
            self.set_dirt(@intCast(old_y), @intCast(self.ocy));
        }
    }
    // NOTE: Outputs the character at the current cursor position and updates its position.
    pub inline fn tputc(self: *Term, u: u32) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;

        const x = self.cursor.pos.getX().?;
        const y = self.cursor.pos.getY().?;
        const cols = self.window.tty_grid.getCols().?;
        const rows = self.window.tty_grid.getRows().?;
        if (x < cols and y < rows) {
            screen[@intCast(y)][@intCast(x)] = Glyph{
                .u = u,
                .fg_index = self.cursor.attr.fg_index,
                .bg_index = self.cursor.attr.bg_index,
                .mode = self.cursor.attr.mode,
            };
            self.cursor.pos.addX(x + 1);
            if (self.cursor.pos.getX().? >= cols) {
                self.cursor.pos.addX(0);
                if (self.cursor.pos.getY().? < rows - 1) {
                    self.cursor.pos.addY(y + 1);
                } else {
                    self.tscrollup(self.top, 1);
                }
            }
            self.set_dirt(@intCast(y), @intCast(y));
        }
        self.lastc = u;
    }

    // NOTE: Repeats the last character entered n times.
    inline fn csi_rep(self: *Term, params: []u32) void {
        const n = @min(params[0], 65535);
        if (self.lastc != 0) {
            for (0..n) |_| self.tputc(self.lastc);
        }
    }

    inline fn handle_esc_sequence(self: *Term, sequence: []const u8) void {
        if (util.compare(sequence, "[?1049h")) {
            self.mode.set(.MODE_ALTSCREEN);
        } else if (util.compare(u8, sequence, "[?1049l")) {
            self.mode.unset(.MODE_ALTSCREEN);
        }
    }
    // NOTE: swap alt and main screens
    inline fn swapscreen(self: *Term) void {
        const temp = self.line;
        self.line = self.alt;
        self.alt = temp;
        self.mode.toggle(.MODE_ALTSCREEN);
        self.fulldirt();
    }

    // NOTE: Resizes the terminal to the specified cols and rows.
    inline fn resize(self: *Term, col: u16, rows: u16) !void {
        const new_cols = @max(2, @min(col, c.MAX_COLS));
        const new_rows = @max(2, @min(rows, c.MAX_ROWS));

        if (col < 2 or rows < 2) {
            std.log.warn("Terminal size too small: requested cols={}, rows={}; clamping to cols={}, rows={}", .{ col, rows, new_cols, new_rows });
        }

        if (self.window.tty_grid.getCols().? == new_cols and self.window.tty_grid.getRows().? == new_rows) return;

        var new_line: [c.MAX_ROWS][c.MAX_COLS]Glyph = undefined;
        var new_alt: [c.MAX_ROWS][c.MAX_COLS]Glyph = undefined;
        @memset(&new_line, [_]Glyph{Glyph.initEmpty()} ** c.MAX_COLS);
        @memset(&new_alt, [_]Glyph{Glyph.initEmpty()} ** c.MAX_COLS);

        const copy_rows = @min(self.window.tty_grid.getRows().?, new_rows);
        const copy_cols = @min(self.window.tty_grid.getCols().?, new_cols);
        for (0..copy_rows) |y| {
            util.move(
                Glyph,
                new_line[y][0..copy_cols],
                self.line[y][0..copy_cols],
            );
            util.move(
                Glyph,
                new_alt[y][0..copy_cols],
                self.alt[y][0..copy_cols],
            );
        }

        self.line = new_line;
        self.alt = new_alt;
        self.window.tty_grid = rect.initGrid(new_cols, new_rows);
        self.cursor.pos.addX(@min(self.cursor.pos.getX().?, new_cols - 1));
        self.cursor.pos.addY(@min(self.cursor.pos.getY().?, new_rows - 1));
        self.top = 0;
        self.bot = new_rows - 1;

        self.fulldirt();
        std.log.debug("Resized terminal: cols={}, rows={}", .{ new_cols, new_rows });
    }

    // NOTE: Marks strings containing characters with the given attribute as “dirty”.
    inline fn setdirtattr(self: *Term, attr: Glyph_flags) void {
        const screen = if (self.mode.isSet(.MODE_ALTSCREEN)) &self.alt else &self.line;

        const rows = self.window.tty_grid.getRows().?;
        const cols = self.window.tty_grid.getCols().?;
        var i: u32 = 0;
        while (i < rows) : (i += 1) {
            var j: u32 = 0;
            while (j < cols) : (j += 1) {
                if (screen[i][j].mode.isSet(attr)) {
                    self.set_dirt(i, i);
                    break;
                }
            }
        }
    }
    // NOTE: Marks lines from top to bot as “dirty” for redrawing.
    //for example from 5 to 10 lines are dirty
    pub inline fn set_dirt(self: *Term, top: u16, bot: u16) void {
        const rows = self.window.tty_grid.getRows().?;
        if (top > bot or bot >= rows or c.MAX_ROWS == 0) return;
        const start = top;
        const end = @min(bot, rows - 1);
        const one: usize = 1;
        self.dirty.setRangeValue(.{ .start = start, .end = end + one }, true);
    }

    pub inline fn fulldirt(self: *Term) void {
        self.set_dirt(0, self.window.tty_grid.getRows().? - 1);
    }
    // NOTE: Calculates the length of the string, ignoring end spaces.
    inline fn linelen(self: *Term, y: u32) u32 {
        var i = self.window.tty_grid.getCols().?;

        if (self.line[y][i - 1].mode.isSet((Glyph_flags.ATTR_WRAP)))
            return i;
        while (i > 0 and self.line[y][i - 1].u == ' ')
            i -= 1;

        return i;
    }

    // NOTE: Processes graphic rendering parameters (colors, styles).
    inline fn handle_sgr(self: *Term, params: []u32) void {
        var i: usize = 0;
        while (i < params.len) {
            const n = params[i];
            switch (n) {
                0 => self.cursor.attr = Glyph.initEmpty(),
                1 => self.cursor.attr.mode.set(.ATTR_BOLD),
                2 => self.cursor.attr.mode.set(.ATTR_FAINT),
                3 => self.cursor.attr.mode.set(.ATTR_ITALIC),
                4 => self.cursor.attr.mode.set(.ATTR_UNDERLINE),
                5, 6 => self.cursor.attr.mode.set(.ATTR_BLINK),
                7 => self.cursor.attr.mode.set(.ATTR_REVERSE),
                8 => self.cursor.attr.mode.set(.ATTR_INVISIBLE),
                9 => self.cursor.attr.mode.set(.ATTR_STRUCK),
                22 => self.cursor.attr.mode.unset(.ATTR_BOLD),
                23 => self.cursor.attr.mode.unset(.ATTR_ITALIC),
                24 => self.cursor.attr.mode.unset(.ATTR_UNDERLINE),
                25 => self.cursor.attr.mode.unset(.ATTR_BLINK),
                27 => self.cursor.attr.mode.unset(.ATTR_REVERSE),
                28 => self.cursor.attr.mode.unset(.ATTR_INVISIBLE),
                29 => self.cursor.attr.mode.unset(.ATTR_STRUCK),
                30...37 => self.cursor.attr.fg_index = @intCast(n - 30),
                40...47 => self.cursor.attr.bg_index = @intCast(n - 40),
                90...97 => self.cursor.attr.fg_index = @intCast(n - 90 + 8),
                100...107 => self.cursor.attr.bg_index = @intCast(n - 100 + 8),
                38, 48 => {
                    if (i + 2 < params.len and params[i + 1] == 5) {
                        if (n == 38) self.cursor.attr.fg_index = @intCast(params[i + 2]) else self.cursor.attr.bg_index = @intCast(params[i + 2]);
                        i += 2;
                    } else {
                        std.log.debug("Unsupported extended color code: {}", .{n});
                    }
                },
                39 => self.cursor.attr.fg_index = c.defaultfg,
                49 => self.cursor.attr.bg_index = c.defaultbg,
                else => std.log.debug("Unhandled SGR code: {}", .{n}),
            }
            i += 1;
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
    // POSITION x and y
    pos: rect = rect.initPosition(0, 0), // pos.x and pos.y for cursor position
    state: CursorMode,
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

    pub inline fn cval_pixman(self: *RenderColor) *c.pixman_color_t {
        return @ptrCast(@alignCast(self));
    }
};

const Color = packed struct(u96) {
    pixel: u32,
    color: RenderColor,
};

//TODO:function for epoll events with getting fd from conn,MAKE ALL XCB CALLS CLEAR,MEMORY LEAKS NOW,CACHE atoms,change doc about windows
// esc commansd \e[2J to clear the screen, \e[H to move the cursor).
// ring buffer and event loop for pty read

//===================================XCB_UTILS======================================================//
pub fn get_root_window(conn: *c.xcb_connection_t) c.xcb_window_t {
    if (!S.root_initialized) {
        const screen = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data;
        S.root_window = screen.*.root;
        S.root_initialized = true;
    }
    return S.root_window;
}

pub fn get_drawable_size(conn: *c.xcb_connection_t, drawable: c.xcb_drawable_t) !c.xcb_rectangle_t {
    const cookie = c.xcb_get_geometry(conn, drawable);

    var err: ?*c.xcb_generic_error_t = null;
    const geom = c.xcb_get_geometry_reply(conn, cookie, &err);

    if (err != null) {
        std.log.err("XCB geometry error: {}", .{err.?.error_code});
        return error.GeometryRequestFailed;
    }
    defer std.c.free(geom);

    if (geom == null) {
        return error.NullGeometryReply;
    }

    return c.xcb_rectangle_t{
        .width = geom.?.*.width,
        .height = geom.?.*.height,
        .x = geom.?.*.x,
        .y = geom.?.*.y,
    };
}

pub fn get_main_window(conn: *c.xcb_connection_t) c.xcb_window_t {
    if (!S.main_initialized) {
        S.main_window_id = c.xcb_generate_id(conn);
        S.main_initialized = true;
    }
    return S.main_window_id;
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

inline fn get_colormap(
    conn: *c.xcb_connection_t,
) c.xcb_colormap_t {
    return c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data.*.default_colormap;
}

pub inline fn get_geometry_reply(xc: *c.xcb_connection_t, cookie: c.xcb_get_geometry_cookie_t) !TermWindow {
    const reply = c.xcb_get_geometry_reply(xc, cookie, null) orelse {
        std.log.err("Could not get geometry", .{});
        return error.CannotGetGeometry;
    };
    defer std.c.free(reply);
    const height = reply.*.height;
    return TermWindow{
        .mode = WinMode.initEmpty(),
        .win_size = rect.initSize(reply.*.width, height),
    };
}
pub inline fn get_geometry(xc: *c.xcb_connection_t, f: Font) !TermWindow {
    var geo = try get_geometry_reply(xc, c.xcb_get_geometry(xc, get_main_window(xc)));
    geo.win_size.data.size.width -= geo.win_size.getWidth().? % f.size.getWidth().?;
    geo.win_size.data.size.height -= geo.win_size.getHeight().? % f.size.getHeight().?;

    return geo;
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

// Resize window and its subwindows
pub fn resize_window(conn: *c.xcb_connection_t, f: Font) void {
    const geo = get_geometry(conn, f) catch |err| {
        std.log.err("Failed to get geometry: {}", .{err});
        return;
    };
    const vt_values = [_]u16{ geo.win_size.getWidth().?, geo.win_size.getHeight().? };
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
        @intCast(win.win_size.getWidth().?),
        @intCast(win.win_size.getHeight().?),
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
pub inline fn set_fg(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    pixel: u32,
) void {
    const values = [_]u32{ pixel, 0 };
    const cookie = c.xcb_change_gc_checked(conn, gc, c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &values);
    XlibTerminal.testCookie(cookie, conn, "cannot set foreground color");
}

pub inline fn set_bg(
    conn: *c.xcb_connection_t,
    gc: c.xcb_gcontext_t,
    pixel: u32,
) void {
    const values = [_]u32{ pixel, 0 };
    const cookie = c.xcb_change_gc_checked(conn, gc, c.XCB_GC_BACKGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &values);
    XlibTerminal.testCookie(cookie, conn, "cannot set background color");
}

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

//==========================================================================================//

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
//
//
//

pub const rect = struct {
    // y
    // │
    // │         x
    // o───────────────────────────────────┐
    // │                                   │
    // │                                   │
    // │                                   │  height
    // │                                   │
    // │                                   │
    // └───────────────────────────────────┘
    //             ←── width ──→
    //
    // For grid:
    // +-----+-----+-----+-----+-----+
    // |     |     |     |     |     |  ← row 0
    // +-----+-----+-----+-----+-----+
    // |     |     |     |     |     |  ← row 1
    // +-----+-----+-----+-----+-----+
    // |     |     |     |     |     |  ← row 2
    // +-----+-----+-----+-----+-----+
    //   ↑     ↑     ↑     ↑     ↑
    // col 0 col 1 col 2 col 3 col 4
    //
    // Example with grid and full:
    // Columns →   -3     -2     -1      0      1      2      3      4      5      6
    //             |       |      |      |      |      |      |      |      |      |
    //             +-------+------+------+------+------+------+------+------+------+------+
    // Row -1      |       +---------------------------+                              |
    //             |       |      |      |      |      |      |      |               |
    // Row  0      |       |  +---+---+---+---+---+   |                              |
    //             |       |  |   |   |   |   |   |   |                              |
    // Row  1      |       |  +---+---+---+---+---+   |                              |
    //             |       |  |   |   |   |   |   |   |                              |
    // Row  2      |       |  +---+---+---+---+---+   |                              |
    //             |       +---------------------------+                              |
    //             +-------+------+------+------+------+------+------+------+------+------+
    //                   ↑      ↑      ↑      ↑      ↑      ↑
    //                  -2     -1      0      1      2      3
    //
    // rect.full: x = -2, y = -1, width = 6, height = 3
    // rect.grid: cols = 5, rows = 3 (within the full rect or window)
    //+-----+-----+-----+-----+-----+
    // |     |     |     |     |     |  ← row 0
    // +-----+-----+-----+-----+-----+
    // |     |     |     |     |     |  ← row 1
    // +-----+-----+-----+-----+-----+
    // |     |     |     |     |     |  ← row 2
    // +-----+-----+-----+-----+-----+
    //   ↑     ↑     ↑     ↑     ↑
    //  col 0 col 1 col 2 col 3 col 4
    data: union(enum) {
        full: struct { // full is basic rectangle
            x: i16,
            y: i16,
            width: u16,
            height: u16,
        },
        position: struct {
            x: i16,
            y: i16,
        },
        size: struct {
            width: u16,
            height: u16,
        },
        grid: struct {
            cols: u16,
            rows: u16,
        },
    },

    pub inline fn cval(self: *rect) *c.xcb_rectangle_t {
        return switch (self.data) {
            .full => |*f| @ptrCast(@alignCast(f)),
            .size => |s| {
                var new_rect = rect{
                    .data = .{
                        .full = .{
                            .x = 0,
                            .y = 0,
                            .width = s.width,
                            .height = s.height,
                        },
                    },
                };
                return @ptrCast(@alignCast(&new_rect.data.full));
            },
            .position => |p| {
                var new_rect = rect{
                    .data = .{
                        .full = .{
                            .x = p.x,
                            .y = p.y,
                            .width = 0,
                            .height = 0,
                        },
                    },
                };
                return @ptrCast(@alignCast(&new_rect.data.full));
            },
            .grid => |g| {
                var new_rect = rect{
                    .data = .{
                        .full = .{
                            .x = 0,
                            .y = 0,
                            .width = g.cols,
                            .height = g.rows,
                        },
                    },
                };
                return @ptrCast(@alignCast(&new_rect.data.full));
            },
        };
    }

    ///  create full rect (x, y, width, height)
    pub fn initFull(x: i16, y: i16, width: u16, height: u16) rect {
        return .{ .data = .{ .full = .{ .x = x, .y = y, .width = width, .height = height } } };
    }

    /// create rect only with position (x, y)
    pub fn initPosition(x: i16, y: i16) rect {
        return .{ .data = .{ .position = .{ .x = x, .y = y } } };
    }

    /// create rect only with (width, height)
    pub fn initSize(width: u16, height: u16) rect {
        return .{ .data = .{ .size = .{ .width = width, .height = height } } };
    }
    /// create rect only with (cols, rows)
    pub fn initGrid(cols: u16, rows: u16) rect {
        return .{ .data = .{ .grid = .{ .cols = cols, .rows = rows } } };
    }

    /// add or update (x, y) in rect
    pub inline fn addPosition(self: *rect, x: i16, y: i16) void {
        switch (self.data) {
            .full => |*f| {
                f.x = x;
                f.y = y;
            },
            .position => |*p| {
                p.x = x;
                p.y = y;
            },
            .size => {
                std.log.warn("cannot add x and y into size which provides only width and height", .{});
            },
            .grid => {
                std.log.warn("cannot add x and y into grid which provides only cols and rows", .{});
            },
        }
    }

    pub inline fn addX(self: *rect, x: i16) void {
        switch (self.data) {
            .full => |*f| {
                f.x = x;
            },
            .position => |*p| {
                p.x = x;
            },
            .size => {
                std.log.warn("cannot add x  into size which provides only width and height", .{});
            },
            .grid => {
                std.log.warn("cannot add x  into grid which provides only cols and rows", .{});
            },
        }
    }

    pub inline fn addY(self: *rect, y: i16) void {
        switch (self.data) {
            .full => |*f| {
                f.y = y;
            },
            .position => |*p| {
                p.y = y;
            },
            .size => {
                std.log.warn("cannot add y  into size which provides only width and height", .{});
            },
            .grid => {
                std.log.warn("cannot add y  into grid which provides only cols and rows", .{});
            },
        }
    }

    inline fn addWidth(self: *rect, width: u16) void {
        switch (self.data) {
            .full => |*f| {
                f.width = width;
            },
            .position => {
                std.log.warn("cannot add width into position which provides only x and y", .{});
            },
            .size => |*s| {
                s.width = width;
            },
            .grid => {
                std.log.warn("cannot add width  into grid which provides only cols and rows; use cols and rows instead", .{});
            },
        }
    }

    inline fn addCols(self: *rect, cols: u16) void {
        switch (self.data) {
            .full => {
                std.log.warn("cannot add cols into full which provides only rectangle", .{});
            },

            .position => {
                std.log.warn("cannot add cols into position which provides only x and y", .{});
            },
            .size => {
                std.log.warn("cannot add cols to size, which provide only width and height", .{});
            },
            .grid => |*g| {
                g.cols = cols;
            },
        }
    }

    inline fn addRows(self: *rect, rows: u16) void {
        switch (self.data) {
            .full => {
                std.log.warn("cannot add rows into full which provides only rectangle", .{});
            },

            .position => {
                std.log.warn("cannot add rows into position which provides only x and y", .{});
            },
            .size => {
                std.log.warn("cannot add rows to size, which provide only width and height", .{});
            },
            .grid => |*g| {
                g.rows = rows;
            },
        }
    }

    inline fn addHeight(self: *rect, height: u16) void {
        switch (self.data) {
            .full => |*f| {
                f.height = height;
            },

            .position => {
                std.log.warn("cannot add height into position which provides only x and y", .{});
            },
            .size => |*s| {
                s.height = height;
            },
            .grid => {
                std.log.warn("cannot add height  into grid which provides only cols and rows; use cols and rows instead", .{});
            },
        }
    }

    /// add or update (width, height) in rect
    pub inline fn addSize(self: *rect, width: u16, height: u16) void {
        switch (self.data) {
            .full => |*f| {
                f.width = width;
                f.height = height;
            },
            .position => {
                std.log.warn("cannot add width and height into position which provides only x and y", .{});
            },
            .size => |*s| {
                s.width = width;
                s.height = height;
            },
            .grid => {
                std.log.warn("cannot add width and height into grid which provides only cols and rows; use cols and rows instead", .{});
            },
        }
    }

    /// add or update (cols, rows) in rect
    pub inline fn addGrid(self: *rect, cols: u16, rows: u16) void {
        switch (self.data) {
            .full => |*f| {
                f.width = cols;
                f.height = rows;
            },
            .position => {
                std.log.warn("cannot add cols and rows into position which provides only x and y", .{});
            },
            .size => {
                std.log.warn("cannot add cols and rows into size which provides only width and height; use width and height instead", .{});
            },
            .grid => |*g| {
                g.cols = cols;
                g.rows = rows;
            },
        }
    }

    /// offset location x, y
    pub inline fn offset(self: *rect, x: i16, y: i16) void {
        switch (self.data) {
            .full => |*f| {
                f.x = std.math.add(i16, f.x, x) catch f.x;
                f.y = std.math.add(i16, f.y, y) catch f.y;
            },
            .position => |*p| {
                p.x = std.math.add(i16, p.x, x) catch p.x;
                p.y = std.math.add(i16, p.y, y) catch p.y;
            },
            .size => {}, // none
            .grid => {}, // none, as grid does not have positional data
        }
    }
    /// merge two rect, create new rect with new information
    pub inline fn merge(self: rect, other: rect) ?rect {
        const x = self.getX() orelse other.getX() orelse return null;
        const y = self.getY() orelse other.getY() orelse return null;
        const width = self.getWidth() orelse other.getWidth() orelse self.getCols() orelse other.getCols() orelse return null;
        const height = self.getHeight() orelse other.getHeight() orelse self.getRows() orelse other.getRows() orelse return null;
        return rect.initFull(x, y, width, height);
    }
    /// is full information availbable? (x, y, width, height)
    pub inline fn isFull(self: rect) bool {
        return switch (self.data) {
            .full => true,
            else => false,
        };
    }

    pub inline fn getX(self: rect) ?i16 {
        return switch (self.data) {
            .full => |f| f.x,
            .position => |p| p.x,
            .size => null,
            .grid => null,
        };
    }

    pub inline fn getY(self: rect) ?i16 {
        return switch (self.data) {
            .full => |f| f.y,
            .position => |p| p.y,
            .size => null,
            .grid => null,
        };
    }

    pub inline fn getWidth(self: rect) ?u16 {
        return switch (self.data) {
            .full => |f| f.width,
            .size => |s| s.width,
            .position => null,
            .grid => null, // Use getCols for grid
        };
    }

    pub inline fn getHeight(self: rect) ?u16 {
        return switch (self.data) {
            .full => |f| f.height,
            .size => |s| s.height,
            .position => null,
            .grid => null, // Use getRows for grid
        };
    }

    pub inline fn getCols(self: rect) ?u16 {
        return switch (self.data) {
            .grid => |g| g.cols,
            .full => null,
            .size => null,
            .position => null,
        };
    }

    pub inline fn getRows(self: rect) ?u16 {
        return switch (self.data) {
            .grid => |g| g.rows,
            .full => null,
            .size => null,
            .position => null,
        };
    }
    // Explanation:
    // - x = -2 says that the left edge of the rectangle goes 2 columns “to the left” beyond the visible area.
    // - y = -1 means that the top edge is one row “above” the first visible row.
    // - width/height are counted in cells (characters).
    // - Negative coordinates are usually used when rendering off-screen elements,
    // scrolling or animation effects, when part of the rectangle is not yet on the screen.

};

//TODO: add it to xlibterminal to get_atom from cache instead of function call
const Atoms = packed struct {
    _NET_WM_PID: c.xcb_atom_t,
    _NET_WM_NAME: c.xcb_atom_t,
    _NET_WM_ICON_NAME: c.xcb_atom_t,
    _NET_WM_STATE: c.xcb_atom_t,
    _NET_WM_STATE_FULLSCREEN: c.xcb_atom_t,
    _NET_WM_STATE_MAXIMIZED_VERT: c.xcb_atom_t,
    _NET_WM_STATE_MAXIMIZED_HORZ: c.xcb_atom_t,
    _NET_ACTIVE_WINDOW: c.xcb_atom_t,
    _NET_MOVERESIZE_WINDOW: c.xcb_atom_t,
    WM_DELETE_WINDOW: c.xcb_atom_t,
    WM_PROTOCOLS: c.xcb_atom_t,
    WM_NORMAL_HINTS: c.xcb_atom_t,
    WM_SIZE_HINTS: c.xcb_atom_t,
    WM_CHANGE_STATE: c.xcb_atom_t,
    UTF8_STRING: c.xcb_atom_t,
    CLIPBOARD: c.xcb_atom_t,
    INCR: c.xcb_atom_t,
    TARGETS: c.xcb_atom_t,
};

pub const XlibTerminal = struct {
    //========main struct=========//=
    connection: *c.xcb_connection_t,
    //============================//=
    screen: *c.xcb_screen_t,
    pixmap: c.xcb_pixmap_t,
    keysyms: *c.xcb_key_symbols_t,
    allocator: Allocator,
    pty: justty.Pty,
    pid: posix.pid_t,
    signalfd: posix.fd_t,
    visual: VisualData,
    xrender_font: Font,
    buf: *Buf.Buf,

    dc: DC,
    term: Term, // Buffer to store pty output
    // win: TermWindow,
    output_len: usize = 0, // Length of stored output

    xkb_context: *Keysym.Context,
    xkb_keymap: *Keysym.Keymap,
    xkb_state: *Keysym.State,

    extern "c" fn sigemptyset(set: *posix.sigset_t) c_int;
    extern "c" fn sigaddset(dest: *posix.sigset_t, signum: c_int) c_int;
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

        //keysyms
        const keysyms = c.xcb_key_symbols_alloc(connection);

        const xkb_context = Keysym.Context.new(.no_flags) orelse return error.XkbContextNewFailed;
        errdefer xkb_context.unref();

        const xkb_keymap = Keysym.Keymap.newFromNames(xkb_context, null, .no_flags) orelse return error.XkbKeymapNewFailed;
        errdefer xkb_keymap.unref();

        const xkb_state = Keysym.State.new(xkb_keymap) orelse return error.XkbStateNewFailed;
        errdefer xkb_state.unref();

        const font_query = c.font;
        var xrender_font = try font.RenderFont.init(connection, allocator, font_query[0..]);
        errdefer xrender_font.deinit();
        std.log.info("Font initialized: query={s}, dpi={d}", .{ font_query[0..], @as(u16, @intFromFloat(xrender_font.dpi)) });

        const cw = @as(u16, @intCast(xrender_font.font.max_advance.x));
        const ch = @as(u16, @intCast(xrender_font.font.max_advance.y));
        if (cw > 72 or ch > 72) {
            std.log.err("Character size too large: cw={}, ch={}. Check font pixel size or DPI.", .{ cw, ch });
            return error.InvalidFontMetrics;
        }

        if (cw < 4 or ch < 4) {
            std.log.err("Character size too small: cw={}, ch={}. Check font pixel size or DPI.", .{ cw, ch });
            return error.InvalidFontMetrics;
        }
        const ascent: u16 = @intCast(xrender_font.font.ascent); // Approximate ascent
        const border_px = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        std.log.info("cw and ch from font: cw={} ch={}", .{ cw, ch });

        const cols_u16 = @as(u16, @intCast(c.cols)); // u8
        const rows_u16 = @as(u16, @intCast(c.rows)); // u8

        // const width_check = try std.math.add(
        //     u16,
        //     try std.math.mul(u16, 2, border_px),
        //     try std.math.mul(u16, cols_u16, cw),
        // );
        const width_check = try countWidth(
            u16,
            border_px,
            cols_u16,
            cw,
        );
        const height_check = try countHeight(
            u16,
            border_px,
            rows_u16,
            ch,
        );
        const win_width = width_check;
        const win_height = height_check;
        if (win_width == 0 or win_height == 0 or win_width > 32767 or win_height > 32767) {
            std.log.err("Invalid window size: width={d}, height={d}", .{ win_width, win_height });
            return error.InvalidWindowSize;
        }
        std.log.info("size windows: width={}, height={}", .{ win_width, win_height });

        var win: TermWindow = .{
            .mode = WinMode.initEmpty(),
            .tty_grid = rect.initGrid(cols_u16, rows_u16),
            .win_size = rect.initSize(win_width, win_height),
            .char_size = rect.initSize(cw, ch),
            .cursor = c.CURSORSHAPE,
        };

        const term: Term = try Term.init(allocator, win);
        var dc: DC = undefined;
        errdefer _ = c.xcb_free_gc(connection, dc.gc);
        win.mode.set(WinModeFlags.MODE_NUMLOCK);

        dc.font = .{
            .size = rect.initSize(cw, ch),
            .ascent = @intCast(ascent),
            .face = xrender_font,
        };

        std.log.debug("dc.col size: {}", .{dc.col.len});
        for (&dc.col, 0..) |*color, i| {
            if (!xloadcolor(connection, visual_data.visual, i, null, color)) {
                if (i < c.colorname.len and c.colorname[i] != null) {
                    std.log.err("cannot allocate color name={s}", .{c.colorname[i].?});
                }
            }
            std.log.debug("Color[{}]: pixel={x:0>8}, R={d}, G={d}, B={d}", .{ i, color.pixel, color.color.red >> 8, color.color.green >> 8, color.color.blue >> 8 });
        }
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
            win.win_size.getWidth().?,
            win.win_size.getHeight().?,
        );
        if (c.xcb_request_check(connection, pixmap_cookie)) |err| {
            std.log.err("cannot create pixmap in xlibinit, error: {}", .{err.*.error_code});
            return error.CannotCreatePixmap;
        }
        var buf = try Buf.Buf.init(
            allocator,
            connection,
            screen,
            pixmap,
            win_width,
            win_height,
        );

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

        // if (try cgroup_buf.current(pid)) |cgroup_path| {
        //     std.log.info("Cgroup path for child process (PID {}): {s}", .{ pid, cgroup_path });
        // } else {
        //     std.log.warn("No cgroup found for child process (PID {})", .{pid});
        // }

        map_windows(connection, dc.font);
        errdefer _ = c.xcb_free_pixmap(connection, pixmap);
        dc.gc = create_gc(connection, dc.gc, get_main_window(connection), dc.col[c.defaultfg].pixel, dc.col[c.defaultbg].pixel);
        const rectangle = c.xcb_rectangle_t{
            .x = 0,
            .y = 0,
            .height = win.win_size.getHeight().?,
            .width = win.win_size.getWidth().?,
        };
        _ = c.xcb_poly_fill_rectangle(
            connection,
            pixmap,
            dc.gc,
            1,
            &rectangle,
        );

        _ = c.xcb_flush(connection);

        var sigset: posix.sigset_t = undefined;
        _ = sigemptyset(&sigset);
        _ = sigaddset(&sigset, posix.SIG.TERM);
        _ = sigaddset(&sigset, posix.SIG.INT);
        _ = sigaddset(&sigset, posix.SIG.HUP);
        posix.sigprocmask(posix.SIG.BLOCK, &sigset, null);

        const sfd = posix.signalfd(-1, &sigset, linux.SFD.CLOEXEC) catch |err| {
            std.log.err("Failed to create signalfd: {}", .{err});
            return err;
        };
        errdefer posix.close(sfd);

        return .{
            .buf = &buf,
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
            .signalfd = sfd,
            .dc = dc,
            // .win = win,
            .keysyms = keysyms.?,
            .xkb_context = xkb_context,
            .xkb_keymap = xkb_keymap,
            .xkb_state = xkb_state,
        };
    }

    pub fn set_title(self: *XlibTerminal, title: []const u8) !void {
        const atom_name = c.XCB_ATOM_WM_NAME;
        const prop_mode = c.XCB_PROP_MODE_REPLACE;
        _ = c.xcb_change_property(
            self.connection,
            prop_mode,
            get_main_window(self.connection),
            atom_name,
            c.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );
        _ = c.xcb_flush(self.connection);
        std.log.debug("Set window title: {s}", .{title});
    }

    fn reset(self: *Self, xterm: *XlibTerminal) void {
        xterm.term.esc_mode = EscMode.initEmpty();
        self.esc_len = 0;
        self.narg = 0;
        self.priv = 0;
        self.mode = [_]u8{ 0, 0 };
    }

    pub fn ttywrite(self: *Self, buf: []const u8, len: usize, flush: u8) void {
        const write_len = @min(len, buf.len);
        _ = self.pty.write(buf[0..write_len]) catch |err| {
            std.log.err("ttywrite error: {}", .{err});
        };
        if (flush != 0) {
            _ = c.xcb_flush(self.connection);
        }
    }

    // The function traverses all rows and columns of the current screen (term.line).
    // Each character (Glyph.u) is converted to UTF-8 using util.utf8Encode.
    // Empty spaces at the end of lines are ignored to avoid unnecessary output.
    // A \n is appended after each line.
    // Data is buffered and sent to PTY via ttywrite.
    // Logging is added for debugging.
    fn tdump(self: *Self) void {
        const cols = self.term.window.tty_grid.getCols().?;
        const rows = self.term.window.tty_grid.getRows().?;
        var buffer: [4096]u8 = undefined;
        var buf_pos: usize = 0;

        for (self.term.line[0..rows], 0..) |line, y| {
            const line_len = self.term.linelen(@intCast(y));
            for (line[0..line_len], 0..) |glyph, x| {
                if (glyph.u == ' ' and x == cols - 1) continue;
                const utf8_len = util.utf8Encode(u32, glyph.u, buffer[buf_pos..]);
                buf_pos += utf8_len;

                if (buf_pos >= buffer.len - utf_size) {
                    self.ttywrite(buffer[0..buf_pos], buf_pos, 0);
                    buf_pos = 0;
                }
            }

            if (buf_pos + 1 < buffer.len) {
                buffer[buf_pos] = '\n';
                buf_pos += 1;
            }
        }

        if (buf_pos > 0) {
            self.ttywrite(buffer[0..buf_pos], buf_pos, 1);
        }

        std.log.debug("tdump: Dumped {} rows, {} cols", .{ rows, cols });
    }

    // The validity of the line index (y) is checked.
    // Only the term.line[y] string is processed.
    // Characters are converted to UTF-8, empty spaces are ignored.
    // An \n is added to the end of the line.
    // Data is sent via ttywrite.
    fn tdumpline(self: *Self, y: i16) void {
        if (y >= self.term.window.tty_grid.getRows().?) {
            std.log.warn("tdumpline: Invalid row index {}", .{y});
            return;
        }

        const cols = self.term.window.tty_grid.getCols().?;
        var buffer: [4096]u8 = undefined;
        var buf_pos: usize = 0;

        for (self.term.line[@intCast(y)][0..cols]) |glyph| {
            if (glyph.u == ' ') continue;

            const utf8_len = util.utf8Encode(u32, glyph.u, buffer[buf_pos..]);
            buf_pos += utf8_len;

            if (buf_pos >= buffer.len - utf_size) {
                self.ttywrite(buffer[0..buf_pos], buf_pos, 0);
                buf_pos = 0;
            }
        }

        if (buf_pos + 1 < buffer.len) {
            buffer[buf_pos] = '\n';
            buf_pos += 1;
        }

        if (buf_pos > 0) {
            self.ttywrite(buffer[0..buf_pos], buf_pos, 1);
        }

        std.log.debug("tdumpline: Dumped row {}", .{y});
    }
    fn tdumpsel(_: *Self) void {
        // check selected test
        // const selected_text = self.primary orelse self.selection.clipcopy.clipboard orelse {
        //     std.log.debug("tdumpsel: No selection available", .{});
        //     return;
        // };

        // self.ttywrite(selected_text, selected_text.len, 1);

        // std.log.debug("tdumpsel: Dumped selection of length {}", .{selected_text.len});
    }
    fn csihandle(self: *XlibTerminal, parser: *escapes.Parser) !void {
        const params = parser.params[0..parser.narg];
        switch (@as(escapes.CSI_ENUM, @enumFromInt(parser.mode[0]))) {
            .InsertCharacters => try self.term.csi_ich(params),
            .CursorUp => try self.term.csi_cuu(params),
            .CursorDown => self.term.csi_cud(params),
            .MediaControl => self.term.csi_mc(params, self),
            .DeviceAttributes => self.term.csi_da(params, self),
            .CursorForward => self.term.csi_cuf(params),
            .CursorBack => try self.term.csi_cub(params),
            .CursorNextLine => self.term.csi_cnl(params),
            .CursorPreviousLine => self.term.csi_cpl(params),
            .CharacterTabulation => self.term.csi_cht(params),
            .CharacterBackwardsTabulation => self.term.csi_cbt(params),
            .CursorHorizontalAbsolute => self.term.csi_cha(params),
            .CursorPosition => self.term.csi_cup(params),
            .EraseInDisplay => self.term.csi_ed(params),
            .EraseInLine => self.term.csi_el(params),
            .ScrollUp => if (parser.priv == 0) self.term.csi_su(params) else std.log.warn("Unknown private SU sequence", .{}),
            .ScrollDown => self.term.csi_sd(params),
            .InsertLine => self.term.csi_il(params),
            .DeleteLine => self.term.csi_dl(params),
            .EraseCharacters => self.term.csi_ech(params),
            .DeleteCharacters => self.term.csi_dch(params),
            .VerticalPositionAbsolute => self.term.csi_vpa(params),
            .SelectGraphicRendition => {
                if (parser.narg == 0) {
                    self.term.handle_sgr(params);
                } else {
                    self.term.csi_sgr(params, parser.narg);
                }
            },
            .DeviceStatusReport => self.term.csi_dsr(params, self),
            .DECSTBM => if (parser.priv == 0) self.term.csi_decstbm(params) else std.log.warn("Unknown private DECSTBM sequence", .{}),
            .SaveCursorPosition => self.term.tcursor(.CURSOR_SAVE),
            .RestoreCursorPosition => self.term.tcursor(.CURSOR_LOAD),
            else => {
                std.log.err("Unknown CSI sequence: mode[0]={c}", .{parser.mode[0]});
            },
        }
    }
    inline fn scrollUp(self: *Self, rows: u16) void {
        const shift = @min(rows, self.term.window.tty_grid.getRows().? - 1);
        if (shift == 0) return;
        util.move(
            [c.MAX_COLS]Glyph,
            self.term.line[0 .. self.term.window.tty_grid.getRows().? - shift],
            self.term.line[shift..self.term.window.tty_grid.getRows().?],
        );
        for (self.term.window.tty_grid.getRows().? - shift..self.term.window.tty_grid.getRows().?) |i| {
            @memset(&self.term.line[i], Glyph.initEmpty());
        }
        self.term.fulldirt();
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

    pub fn process_input(self: *XlibTerminal, data: []const u8) !void {
        if (self.term.mode.isSet(.MODE_ECHO)) {
            _ = self.pty.write(data) catch |err| {
                std.log.err("Failed to echo to PTY: {}", .{err});
            };
        }
        try self.term.parser.process_input(&self.term, self, data);
    }

    // pub fn process_input(self: *XlibTerminal, data: []const u8) !void {
    //     var pos: usize = 0;
    //     const codepoint_count = util.countUtf8CodePoints(data);
    //     const utf32_buffer = try self.allocator.alloc(u32, codepoint_count);
    //     defer self.allocator.free(utf32_buffer);
    //
    //     while (pos < data.len) {
    //         const valid_len = util.utf8_validate_pos(data[pos..]) orelse {
    //             std.log.warn("Invalid UTF-8 byte at pos {}", .{pos});
    //             pos += 1;
    //             continue;
    //         };
    //         const chunk = data[pos .. pos + valid_len];
    //         pos += valid_len;
    //
    //         const codepoints = util.decode_utf8_to_utf32(chunk, utf32_buffer) catch |err| {
    //             std.log.err("UTF-8 decode error: {}", .{err});
    //             continue;
    //         };
    //
    //         if (self.term.mode.isSet(.MODE_ECHO)) {
    //             _ = self.pty.write(chunk) catch |err| {
    //                 std.log.err("Failed to echo to PTY: {}", .{err});
    //             };
    //         }
    //
    //         for (codepoints) |codepoint| {
    //             if (self.term.esc_mode.isSet(.ESC_START)) {
    //                 var utf8_buf: [4]u8 = undefined;
    //                 const len = util.utf8Encode(u32, codepoint, &utf8_buf);
    //                 try self.term.csi_escape.parse_esc(self, utf8_buf[0..len]);
    //                 continue;
    //             }
    //
    //             switch (codepoint) {
    //                 0x1B => {
    //                     self.term.esc_mode.set(.ESC_START);
    //                     continue;
    //                 },
    //                 '\n' => {
    //                     self.term.cursor.pos.addX(0);
    //                     if (self.term.cursor.pos.getY().? < self.term.window.tty_grid.getRows().? - 1) {
    //                         self.term.cursor.pos.data.position.y += 1;
    //                     } else {
    //                         self.scrollUp(1);
    //                     }
    //                     self.term.set_dirt(@intCast(self.term.cursor.pos.getY().?), @intCast(self.term.cursor.pos.getY().?));
    //                 },
    //                 '\r' => {
    //                     self.term.cursor.pos.addX(0);
    //                     self.term.set_dirt(@intCast(self.term.cursor.pos.getY().?), @intCast(self.term.cursor.pos.getY().?));
    //                 },
    //                 '\x08' => {
    //                     if (self.term.cursor.pos.getX().? > 0) {
    //                         self.term.cursor.pos.data.position.x -= 1;
    //                         self.term.line[@intCast(self.term.cursor.pos.getY().?)][@intCast(self.term.cursor.pos.getX().?)] = Glyph.initEmpty();
    //                         self.term.set_dirt(@intCast(self.term.cursor.pos.getY().?), @intCast(self.term.cursor.pos.getY().?));
    //                     }
    //                 },
    //                 '\t' => self.term.tputtab(1),
    //                 else => {
    //                     if (unicode.utf8ValidCodepoint(@intCast(codepoint)) and codepoint >= 0x20) {
    //                         self.term.tputc(codepoint);
    //                     } else {
    //                         std.log.debug("Skipping non-printable codepoint: {x}", .{codepoint});
    //                     }
    //                 },
    //             }
    //         }
    //     }
    // }
    pub fn drawline(self: *XlibTerminal, x1: u16, y1: u16, x2: u16) void {
        const row = self.term.line[y1][x1..x2];
        try self.xdrawglyphfontspecs(row, x1, y1, x2 - x1);
    }

    pub fn xdrawglyphfontspecs(self: *XlibTerminal, glyphs: []const Glyph, x: u16, y: u16, len: usize) !void {
        if (len == 0 or len > c.MAX_COLS) {
            std.log.err("Invalid glyph length: {d}", .{len});
            return error.InvalidGlyphLength;
        }

        const borderpx = @max(@as(u16, @intCast(c.borderpx)), 1);
        const char_width = self.dc.font.size.getWidth().?;
        const char_height = self.dc.font.size.getHeight().?;
        const ascent = self.dc.font.ascent;

        if (char_width == 0 or char_height == 0 or char_width > 72 or char_height > 72 or ascent > 72) {
            std.log.err("Invalid font metrics: width={d}, height={d}, ascent={d}", .{ char_width, char_height, ascent });
            return error.InvalidFontSize;
        }

        // Precompute coordinates with overflow checks
        const x_scaled = std.math.mul(u16, x, char_width) catch return error.Overflow;
        const px = std.math.add(u16, borderpx, x_scaled) catch return error.Overflow;
        const y_scaled = std.math.mul(u16, y, char_height) catch return error.Overflow;
        const py_base = std.math.add(u16, borderpx, y_scaled) catch return error.Overflow;
        const py = std.math.add(u16, py_base, @as(u16, @intCast(ascent))) catch return error.Overflow;

        const mask = c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES;

        var start: usize = 0;
        var text: [c.MAX_COLS]u32 = undefined;
        var text_len: u32 = 0;
        var current_glyph = glyphs[0];

        for (glyphs[0..len], 0..) |glyph, i| {
            const is_last = i == len - 1;
            const attrs_differ = if (i > 0) !ATTRCMP(
                current_glyph,
                glyph,
            ) else false;
            if (attrs_differ or is_last) {
                const end = if (is_last and !attrs_differ) i + 1 else i;
                text_len = 0;

                // Filter valid codepoints
                for (glyphs[start..end]) |g| {
                    if (g.u < 0x20 or !unicode.utf8ValidCodepoint(@intCast(g.u))) continue;
                    text[text_len] = g.u;
                    text_len += 1;
                }

                if (text_len > 0) {
                    // Handle colors with reverse mode
                    var fg_pixel = self.dc.col[current_glyph.fg_index].pixel;
                    var bg_pixel = self.dc.col[current_glyph.bg_index].pixel;
                    if (current_glyph.mode.isSet(.ATTR_REVERSE)) {
                        std.mem.swap(@TypeOf(fg_pixel), &fg_pixel, &bg_pixel);
                    }

                    // Set background color and fill rectangle
                    // const bg_pixel = font.color_to_uint32(
                    //     c.xcb_render_color_t,
                    //     bg_color.cval().*,
                    // ) | 0xff000000;
                    const values_bg = [_]u32{ bg_pixel, 0 };
                    _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values_bg);

                    const x_offset = std.math.mul(u16, @as(u16, @intCast(start)), char_width) catch return error.Overflow;
                    const rect_x = std.math.add(u16, px, x_offset) catch return error.Overflow;

                    // Render text with foreground color
                    _ = try self.dc.font.face.drawText(
                        self.buf,
                        text[0..text_len],
                        @intCast(rect_x),
                        @intCast(py),
                        fg_pixel,
                    );
                }

                start = i;
                current_glyph = glyph;
            }
        }

        // Handle remaining glyphs
        if (start < len) {
            text_len = 0;
            for (glyphs[start..len]) |g| {
                if (g.u < 0x20 or !unicode.utf8ValidCodepoint(@intCast(g.u))) continue;
                text[text_len] = g.u;
                text_len += 1;
            }

            if (text_len > 0) {
                var fg_pixel = self.dc.col[current_glyph.fg_index].pixel;
                var bg_pixel = self.dc.col[current_glyph.bg_index].pixel;
                if (current_glyph.mode.isSet(.ATTR_REVERSE)) {
                    std.mem.swap(@TypeOf(fg_pixel), &fg_pixel, &bg_pixel);
                }

                const values_bg = [_]u32{ bg_pixel, 0 };
                _ = c.xcb_change_gc(self.connection, self.dc.gc, mask, &values_bg);

                const x_offset = std.math.mul(u16, @as(u16, @intCast(start)), char_width) catch return error.Overflow;
                const rect_x = std.math.add(u16, px, x_offset) catch return error.Overflow;
                const rect_width = std.math.mul(u16, char_width, @as(u16, @intCast(text_len))) catch return error.Overflow;

                const clear_rect_group = c.xcb_rectangle_t{
                    .x = @intCast(rect_x),
                    .y = @intCast(py_base),
                    .width = @intCast(rect_width),
                    .height = @intCast(char_height),
                };
                _ = c.xcb_poly_fill_rectangle(self.connection, self.pixmap, self.dc.gc, 1, &clear_rect_group);

                _ = try self.dc.font.face.drawText(
                    self.buf,
                    text[0..text_len],
                    @intCast(rect_x),
                    @intCast(py),
                    fg_pixel,
                );
            }
        }

        // Flush to ensure rendering
        _ = c.xcb_flush(self.connection);
    }

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
    pub fn xloadcolor(
        conn: *c.xcb_connection_t,
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
                const success = color_alloc_value(
                    conn,
                    visual,
                    get_colormap(conn),
                    &xcolor,
                    color,
                );
                if (!success) {
                    std.log.err("Failed to allocate color for index {}", .{i});
                    return false;
                }
                return true;
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
                const success = color_alloc_value(
                    conn,
                    visual,
                    get_colormap(conn),
                    &xcolor,
                    color,
                );
                if (!success) {
                    std.log.err("Failed to allocate hex color {s}", .{name});
                    return false;
                }
                return true;
            } else |_| {
                return false;
            }
        }

        const success = color_alloc_name(
            conn,
            get_colormap(conn),
            name,
            color,
        );
        if (!success) {
            return false;
        }
        return true;
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
        const pty_fd = self.pty.master;
        const epfd = try posix.epoll_create1(0);
        defer posix.close(epfd);
        //xcb
        var ev_xfd: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .fd = xfd },
        };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, xfd, &ev_xfd);

        //pty
        var ev_pty: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .fd = pty_fd },
        };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, pty_fd, &ev_pty);

        // signalfd
        var ev_sfd: linux.epoll_event = .{
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .fd = self.signalfd },
        };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, self.signalfd, &ev_sfd);

        var buffer: [c.BUFSIZ]u8 = undefined;
        const poll_timeout_ms = 100;

        var events: [3]linux.epoll_event = undefined;

        while (true) {
            const result = posix.waitpid(self.pid, posix.W.NOHANG);
            if (result.pid > 0) {
                std.log.info("Child process {} exited with status {}", .{ result.pid, result.status });
                self.deinit();
                return;
            }

            const nfds = linux.epoll_wait(epfd, &events, events.len, poll_timeout_ms);

            var input_processed = false;

            if (nfds == 0) {
                if (self.term.dirty.count() > 0) {
                    std.log.debug("Timeout redraw: {} dirty rows", .{self.term.dirty.count()});
                    try self.redraw();
                }
                continue;
            }

            for (events[0..nfds]) |ev| {
                if (ev.data.fd == xfd) {
                    //  XCB
                    if (ev.events & linux.EPOLL.IN != 0) {
                        while (true) {
                            const event = c.xcb_poll_for_event(self.connection) orelse break;
                            defer std.c.free(event);
                            try self.handleEvent(event);
                        }
                    }
                    if (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
                        std.log.err("XCB connection closed or errored: events={x}", .{ev.events});
                        self.deinit();
                        return error.XcbConnectionError;
                    }
                } else if (ev.data.fd == pty_fd) {
                    // PTY
                    if (ev.events & linux.EPOLL.IN != 0) {
                        const n = self.pty.read(&buffer) catch |err| {
                            std.log.err("read error from pty: {}", .{err});
                            self.deinit();
                            return err;
                        };
                        if (n == 0) {
                            std.log.info("Successfully closed PTY", .{});
                            self.deinit();
                            return;
                        }
                        std.log.debug("Raw PTY input ({d} bytes): {x}", .{ n, buffer[0..n] });
                        try self.process_input(buffer[0..n]);
                        input_processed = true;
                    }
                    if (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
                        std.log.err("PTY closed or errored: events={x}", .{ev.events});
                        self.deinit();
                        return error.PtyError;
                    }
                } else if (ev.data.fd == self.signalfd) {
                    // signalfd
                    if (ev.events & linux.EPOLL.IN != 0) {
                        var siginfo: posix.siginfo_t = undefined;
                        const n = posix.read(self.signalfd, std.mem.asBytes(&siginfo)) catch |err| {
                            std.log.err("Failed to read from signalfd: {}", .{err});
                            self.deinit();
                            return err;
                        };
                        if (n != @sizeOf(posix.siginfo_t)) {
                            std.log.err("Invalid signalfd read size: {}", .{n});
                            self.deinit();
                            return error.InvalidSiginfo;
                        }
                        std.log.info("Received signal: signo={}", .{siginfo.signo});
                        self.deinit();
                        return error.SignalReceived;
                    }
                    if (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
                        std.log.err("signalfd closed or errored: events={x}", .{ev.events});
                        self.deinit();
                        return error.SignalFdError;
                    }
                }
            }

            if (input_processed and self.term.dirty.count() > 0) {
                std.log.debug("Triggering redraw: input_processed={}, dirty_count={}", .{ input_processed, self.term.dirty.count() });
                try self.redraw();
            }
        }
    }
    // Test redraw
    // pub fn redraw(self: *XlibTerminal) !void {
    //     const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
    //     std.log.debug("Redrawing screen", .{});

    //     // Clear pixmap with default background
    //     const bg_pixel = self.dc.col[c.defaultbg].pixel | 0xff000000;
    //     const values = [_]u32{ bg_pixel, 0 };
    //     _ = c.xcb_change_gc(self.connection, self.dc.gc, c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &values);
    //     const full_rect = c.xcb_rectangle_t{
    //         .x = 0,
    //         .y = 0,
    //         .width = self.win.win_size.width,
    //         .height = self.win.win_size.height,
    //     };
    //     _ = c.xcb_poly_fill_rectangle(self.connection, self.pixmap, self.dc.gc, 1, &full_rect);

    //     // Test rendering with hard-coded red foreground
    //     var test_glyphs = [_]Glyph{
    //         Glyph{ .u = 'T', .fg_index = 14, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() }, // Red foreground
    //         Glyph{ .u = 'e', .fg_index = 14, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() },
    //         Glyph{ .u = 's', .fg_index = 14, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() },
    //         Glyph{ .u = 't', .fg_index = 14, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() },
    //     };
    //     try self.xdrawglyphfontspecs(test_glyphs[0..], 0, 0, 4);

    //     _ = c.xcb_copy_area(
    //         self.connection,
    //         self.pixmap,
    //         get_main_window(self.connection),
    //         self.dc.gc,
    //         0,
    //         0,
    //         borderpx,
    //         borderpx,
    //         self.win.win_size.width - 2 * borderpx,
    //         self.win.win_size.height - 2 * borderpx,
    //     );

    //     _ = c.xcb_flush(self.connection);
    //     self.term.dirty = DirtySet.initEmpty();
    //     std.log.debug("Redraw complete", .{});
    // }

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

    pub fn set_size_hints(self: *XlibTerminal) void {
        const char_width = self.dc.font.size.getWidth().?;
        const char_height = self.dc.font.size.getHeight().?;
        const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        const hints = [_]u32{
            char_width, // width_inc
            char_height, // height_inc
            2 * borderpx, // base_width
            2 * borderpx, // base_height
                // ... other hints ...
        };
        _ = c.xcb_change_property(
            self.connection,
            c.XCB_PROP_MODE_REPLACE,
            get_main_window(self.connection),
            get_atom(self.connection, "_NET_WM_SIZE_HINTS"),
            c.XCB_ATOM_WM_SIZE_HINTS,
            32,
            hints.len,
            &hints,
        );
    }

    fn keyboardHandle(self: *Self, event: *c.xcb_generic_event_t, seat: *Keysym.State) !void {
        const key_event = @as(*c.xcb_key_press_event_t, @ptrCast(event));
        const keycode = key_event.detail;
        const modifiers = key_event.state;

        _ = Keysym.State.updateKey(seat, keycode, .down);

        const keysym = Keysym.State.keyGetOneSym(seat, keycode);
        var buffer: [32]u8 = undefined;
        const len = Keysym.State.keyGetUtf8(seat, keycode, &buffer);
        const utf8_str = buffer[0..@intCast(len)];

        std.log.debug("Key pressed: keysym={x}, utf8={s}, modifiers={x}", .{ keysym, utf8_str, modifiers });

        if (modifiers & c.XCB_MOD_MASK_SHIFT != 0 and modifiers & c.XCB_MOD_MASK_1 != 0) {
            const components: Keysym.State.Component = @enumFromInt(Keysym.State.Component.layout_effective);
            const current_group = Keysym.State.serializeLayout(seat, components);
            const next_group = (current_group + 1) % 2;
            _ = Keysym.State.updateMask(seat, 0, 0, 0, next_group, 0, 0);
            return;
        }

        switch (keysym) {
            .Return => {
                const char = [_]u8{0x0A};
                try self.term.parser.process_input(&self.term, self, &char);
                if (!self.term.mode.isSet(.MODE_ECHO)) {
                    _ = posix.write(self.pty.master, &char) catch |err| {
                        std.log.err("Failed to write to PTY: {}", .{err});
                    };
                }
                try self.redraw();
            },
            .BackSpace => {
                //  BS
                const char = [_]u8{0x08};
                try self.term.parser.process_input(&self.term, self, &char);
                if (!self.term.mode.isSet(.MODE_ECHO)) {
                    _ = posix.write(self.pty.master, &char) catch |err| {
                        std.log.err("Failed to write to PTY: {}", .{err});
                    };
                }
                try self.redraw();
            },
            .Left => {
                try self.term.csi_cub(@ptrCast(@constCast(&[_]u32{1})));
                try self.redraw();
            },
            .Right => {
                self.term.csi_cuf(@ptrCast(@constCast(&[_]u32{1})));
                try self.redraw();
            },
            .Escape => {
                const char = [_]u8{0x1B};
                try self.term.parser.process_input(&self.term, self, &char);
                if (!self.term.mode.isSet(.MODE_ECHO)) {
                    _ = posix.write(self.pty.master, &char) catch |err| {
                        std.log.err("Failed to write to PTY: {}", .{err});
                    };
                }
                try self.redraw();
            },
            else => {
                if (len > 0) {
                    try self.term.parser.process_input(&self.term, self, utf8_str);
                    if (!self.term.mode.isSet(.MODE_ECHO)) {
                        _ = posix.write(self.pty.master, utf8_str) catch |err| {
                            std.log.err("Failed to write to PTY: {}", .{err});
                        };
                    }
                    try self.redraw();
                }
            },
        }
    }

    fn handleEvent(self: *Self, event: *c.xcb_generic_event_t) !void {
        const event_type = event.response_type & ~@as(u8, 0x80);
        switch (event_type) {
            c.XCB_EXPOSE => {
                const expose_event = @as(*c.xcb_expose_event_t, @ptrCast(event));
                if (expose_event.window == get_main_window(self.connection)) {
                    self.term.fulldirt();
                    try self.redraw();
                }
            },
            c.XCB_KEY_PRESS => {
                const key_event = @as(*c.xcb_key_press_event_t, @ptrCast(event));
                if (key_event.event == get_main_window(self.connection)) {
                    try self.keyboardHandle(event, self.xkb_state);
                }
            },
            c.XCB_CONFIGURE_NOTIFY => {
                const config_event = @as(*c.xcb_configure_notify_event_t, @ptrCast(event));
                if (config_event.window == get_main_window(self.connection)) {
                    const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
                    const effective_width = config_event.width - 2 * borderpx;
                    const effective_height = config_event.height - 2 * borderpx;

                    const new_size = justty.winsize{
                        .ws_row = @intCast(@max(2, @divTrunc(effective_height, @as(u16, @intCast(self.dc.font.size.getHeight().?))))),
                        .ws_col = @intCast(@max(2, @divTrunc(effective_width, @as(u16, @intCast(self.dc.font.size.getWidth().?))))),
                        .ws_xpixel = 0,
                        .ws_ypixel = 0,
                    };
                    try self.pty.resize(new_size);
                    try self.resize(@intCast(config_event.width), @intCast(config_event.height));
                    try self.term.resize(new_size.ws_col, new_size.ws_row);
                    self.term.window.win_size.addWidth(config_event.width);
                    self.term.window.win_size.addHeight(config_event.height);
                    self.set_size_hints();
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

    inline fn resize(self: *XlibTerminal, width: u16, height: u16) !void {
        self.term.window.win_size.addWidth(width);
        self.term.window.win_size.addHeight(height);

        const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        const char_width = self.dc.font.size.getWidth().?;
        const char_height = self.dc.font.size.getHeight().?;
        const cols = @max(1, @as(u16, @intCast((width - 2 * borderpx) / char_width)));
        const rows = @max(1, @as(u16, @intCast((height - 2 * borderpx) / char_height)));

        self.term.window.tty_grid.addCols(cols);
        self.term.window.tty_grid.addRows(rows);

        _ = c.xcb_free_pixmap(self.connection, self.pixmap);
        self.pixmap = c.xcb_generate_id(self.connection);
        _ = c.xcb_create_pixmap(
            self.connection,
            self.visual.visual_depth,
            self.pixmap,
            get_main_window(self.connection),
            width,
            height,
        );

        if (width != self.buf.width or height != self.buf.height) {
            self.buf.deinit();
            var buf = try Buf.Buf.init(
                self.allocator,
                self.connection,
                self.screen,
                self.pixmap,
                width,
                height,
            );
            self.buf = &buf;
        }

        self.buf.setContainerSize(width, height);

        // Clear pixmap with default background
        const bg_pixel = self.dc.col[c.defaultbg].pixel | 0xff000000;
        const values = [_]u32{ bg_pixel, 0 };
        _ = c.xcb_change_gc(self.connection, self.dc.gc, c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES, &values);
        const clear_rect = c.xcb_rectangle_t{ .x = 0, .y = 0, .width = width, .height = height };
        _ = c.xcb_poly_fill_rectangle(self.connection, self.pixmap, self.dc.gc, 1, &clear_rect);

        // Mark all rows dirty and redraw everything
        self.term.fulldirt();
        try self.redraw();

        std.log.info("Resized: width={d}, height={d}, cols={d}, rows={d}", .{ width, height, cols, rows });
    }

    fn computeGlyphPosition(self: *XlibTerminal, x: u16, y: u16) !struct { px: u16, py: u16 } {
        const borderpx = @max(1, @as(u16, @intCast(c.borderpx)));
        const char_width = self.dc.font.size.width;
        const char_height = self.dc.font.size.height;
        const ascent = self.dc.font.ascent;

        const px = try std.math.add(u16, borderpx, try std.math.mul(u16, x, char_width));
        const py_base = try std.math.add(u16, borderpx, try std.math.mul(u16, y, char_height));
        const py = try std.math.add(u16, py_base, @as(u16, @intCast(ascent)));

        return .{ .px = px, .py = py };
    }

    // PROD REDRAW
    pub fn redraw(self: *XlibTerminal) !void {
        if (self.pixmap == 0) {
            std.log.err("Invalid pixmap for redraw", .{});
            return error.InvalidPixmap;
        }
        const borderpx = if (c.borderpx <= 0) 1 else @as(u16, @intCast(c.borderpx));
        std.log.debug("Redrawing screen", .{});

        // Draw only dirty rows
        var i: usize = 0;
        while (i < self.term.window.tty_grid.getRows().?) : (i += 1) {
            if (!self.term.dirty.isSet(@intCast(i))) continue;
            try self.xdrawglyphfontspecs(
                self.term.line[i][0..self.term.window.tty_grid.getCols().?],
                0,
                @intCast(i),
                self.term.window.tty_grid.getCols().?,
            );
        }

        // Copy pixmap to window
        _ = c.xcb_copy_area(
            self.connection,
            self.pixmap,
            get_main_window(self.connection),
            self.dc.gc,
            @intCast(borderpx),
            @intCast(borderpx),
            @intCast(borderpx),
            @intCast(borderpx),
            self.term.window.win_size.getWidth().? - 2 * borderpx,
            self.term.window.win_size.getHeight().? - 2 * borderpx,
        );

        _ = c.xcb_flush(self.connection);
        self.term.dirty = DirtySet.initEmpty();
        std.log.debug("Redraw complete", .{});
    }
    pub fn deinit(self: *Self) void {
        self.pty.deinit();
        self.buf.deinit();
        self.dc.font.face.deinit();
        self.xkb_state.unref();
        self.xkb_keymap.unref();
        self.xkb_context.unref();
        // if (S.main_initialized) {
        //     _ = c.xcb_destroy_window(self.connection, S.main_window_id);
        //     S.main_initialized = false;
        // }
        // if (S.root_initialized) {
        //     _ = c.xcb_destroy_window(self.connection, S.root_window);
        //     S.root_initialized = false;
        // }
        _ = c.xcb_free_gc(self.connection, self.dc.gc);
        _ = c.xcb_free_pixmap(self.connection, self.pixmap);
        _ = c.xcb_destroy_window(self.connection, get_main_window(self.connection)); // Destroy main window
        _ = c.xcb_destroy_window(self.connection, get_root_window(self.connection));
        _ = c.xcb_key_symbols_free(self.keysyms);
        _ = c.xcb_disconnect(self.connection);
        posix.close(self.signalfd);
    }
};

test "Term dirty row handling" {
    const allocator = std.testing.allocator;
    const win: TermWindow = .{
        .mode = WinMode.initEmpty(),
        .tty_grid = rect.initGrid(80, 24),
    };
    var term = try Term.init(allocator, win);

    // Test set_dirt
    term.set_dirt(5, 10);
    try std.testing.expect(term.dirty.isSet(5));
    try std.testing.expect(term.dirty.isSet(10));
    try std.testing.expect(!term.dirty.isSet(11));
    try std.testing.expectEqual(6, term.dirty.count());

    // Test fulldirt
    term.fulldirt();
    try std.testing.expectEqual(24, term.dirty.count());

    // Test invalid range
    term.dirty = DirtySet.initEmpty();
    term.set_dirt(25, 10); // Invalid range
    try std.testing.expectEqual(0, term.dirty.count());
}

test "Term csi_ich" {
    const allocator = std.testing.allocator;
    var term = try Term.init(
        allocator,
        .{
            .mode = WinMode.initEmpty(),
            .tty_grid = rect.initGrid(10, 24),
        },
    );

    const chars = "ABCDEFGHIJ";
    for (chars, 0..) |cc, i| {
        term.line[0][i] = Glyph{ .u = cc, .fg_index = c.defaultfg, .bg_index = c.defaultbg, .mode = GLyphMode.initEmpty() };
    }
    term.cursor.pos.addPosition(2, 0);

    try term.csi_ich(@ptrCast(@constCast(&[_]u32{2})));
    try std.testing.expectEqual('A', term.line[0][0].u);
    try std.testing.expectEqual('B', term.line[0][1].u);
    try std.testing.expectEqual(' ', term.line[0][2].u);
    try std.testing.expectEqual(' ', term.line[0][3].u);
    try std.testing.expectEqual('C', term.line[0][4].u);
    try std.testing.expectEqual('D', term.line[0][5].u);
    try std.testing.expect(term.dirty.isSet(0));
}
