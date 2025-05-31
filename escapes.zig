const std = @import("std");
const c = @import("c.zig");

// https://en.wikipedia.org/wiki/ANSI_escape_code
/// See also: https://en.wikipedia.org/wiki/C0_and_C1_control_codes and `isControl`
/// 7 bit standart ascii escape_codes
pub const C0 = enum(u7) {
    NUL = 0x00,
    /// Null
    /// Start of Heading
    SOH = 0x01,
    /// Start of Text
    STX = 0x02,
    /// End of Text
    ETX = 0x03,
    /// End of Transmission
    EOT = 0x04,
    /// Enquiry
    ENQ = 0x05,
    /// Acknowledge
    ACK = 0x06,
    /// Bell
    BEL = 0x07,
    /// Backspace
    BS = 0x08,
    /// Horizontal Tab
    HT = 0x09,
    /// Line Feed
    LF = 0x0A,
    /// Vertical Tab
    VT = 0x0B,
    /// Form Feed
    FF = 0x0C,
    /// Carriage Return
    CR = 0x0D,
    /// Shift Out
    SO = 0x0E,
    /// Shift In
    SI = 0x0F,
    /// Data Link Escape
    DLE = 0x10,
    /// Device Control 1 (often XON)
    DC1 = 0x11,
    /// Device Control 2
    DC2 = 0x12,
    /// Device Control 3 (often XOFF)
    DC3 = 0x13,
    /// Device Control 4
    DC4 = 0x14,
    /// Negative Acknowledge
    NAK = 0x15,
    /// Synchronous Idle
    SYN = 0x16,
    /// End of Transmission Block
    ETB = 0x17,
    /// Cancel
    CAN = 0x18,
    /// End of Medium
    EM = 0x19,
    /// Substitute
    SUB = 0x1A,
    /// Escape \x1B \033  \e "\0x1B[31mHello\0x1B[0m"
    ESC = 0x1B,
    /// File Separator
    FS = 0x1C,
    /// Group Separator
    GS = 0x1D,
    /// Record Separator
    RS = 0x1E,
    /// Unit Separator
    US = 0x1F,
    /// Delete
    DEL = 0x7F,
};
pub fn isControl(n: u8) bool {
    return n <= @intFromEnum(C0.US) or n == @intFromEnum(C0.DEL);
}

pub const SGR = enum(u8) {
    /// Reset all attributes 0m reset
    Reset = 0,
    /// Bold or increased intensity
    Bold = 1,
    /// Faint or decreased intensity
    Faint = 2,
    /// Italic for example \033[3mtest\033[m
    Italic = 3,
    /// Underline
    Underline = 4,
    /// Slow blink
    BlinkSlow = 5,
    /// Rapid blink
    BlinkRapid = 6,
    /// Reverse video (swap foreground and background)
    Reverse = 7,
    /// Conceal (hide text)
    Conceal = 8,
    /// Crossed-out (strikethrough)
    CrossedOut = 9,

    /// Foreground: Black
    FgBlack = 30,
    /// Foreground: Red
    FgRed = 31,
    /// Foreground: Green
    FgGreen = 32,
    /// Foreground: Yellow
    FgYellow = 33,
    /// Foreground: Blue
    FgBlue = 34,
    /// Foreground: Magenta
    FgMagenta = 35,
    /// Foreground: Cyan
    FgCyan = 36,
    /// Foreground: White
    FgWhite = 37,
    /// Foreground: Default
    FgDefault = 39,

    /// Background: Black
    BgBlack = 40,
    /// Background: Red
    BgRed = 41,
    /// Background: Green
    BgGreen = 42,
    /// Background: Yellow
    BgYellow = 43,
    /// Background: Blue
    BgBlue = 44,
    /// Background: Magenta
    BgMagenta = 45,
    /// Background: Cyan
    BgCyan = 46,
    /// Background: White
    BgWhite = 47,
    /// Background: Default
    BgDefault = 49,

    /// Bright Foreground: Black
    FgBrightBlack = 90,
    /// Bright Foreground: Red
    FgBrightRed = 91,
    /// Bright Foreground: Green
    FgBrightGreen = 92,
    /// Bright Foreground: Yellow
    FgBrightYellow = 93,
    /// Bright Foreground: Blue
    FgBrightBlue = 94,
    /// Bright Foreground: Magenta
    FgBrightMagenta = 95,
    /// Bright Foreground: Cyan
    FgBrightCyan = 96,
    /// Bright Foreground: White
    FgBrightWhite = 97,

    /// Bright Background: Black
    BgBrightBlack = 100,
    /// Bright Background: Red
    BgBrightRed = 101,
    /// Bright Background: Green
    BgBrightGreen = 102,
    /// Bright Background: Yellow
    BgBrightYellow = 103,
    /// Bright Background: Blue
    BgBrightBlue = 104,
    /// Bright Background: Magenta
    BgBrightMagenta = 105,
    /// Bright Background: Cyan
    BgBrightCyan = 106,
    /// Bright Background: White
    BgBrightWhite = 107,
};

pub fn isSGR(n: u8) bool {
    return (n <= 9) or
        (n >= 30 and n <= 39) or
        (n >= 40 and n <= 49) or
        (n >= 90 and n <= 97) or
        (n >= 100 and n <= 107);
}

pub const CSI = enum(u8) {
    /// Cursor Up (CUU)
    CursorUp = 'A',
    /// Cursor Down (CUD)
    CursorDown = 'B',
    /// Cursor Forward (CUF)
    CursorForward = 'C',
    /// Cursor Back (CUB)
    CursorBack = 'D',
    /// Cursor Next Line (CNL)
    CursorNextLine = 'E',
    /// Cursor Previous Line (CPL)
    CursorPreviousLine = 'F',
    /// Cursor Horizontal Absolute (CHA)
    CursorHorizontalAbsolute = 'G',
    /// Cursor Position (CUP)
    CursorPosition = 'H',
    /// Erase in Display (ED)
    EraseInDisplay = 'J',
    /// Erase in Line (EL)
    EraseInLine = 'K',
    /// Scroll Up (SU)
    ScrollUp = 'S',
    /// Scroll Down (SD)
    ScrollDown = 'T',
    /// Horizontal and Vertical Position (HVP), same as CUP
    HorizontalVerticalPosition = 'f',
    /// Select Graphic Rendition (SGR)
    SelectGraphicRendition = 'm',
    /// Device Status Report (DSR)
    DeviceStatusReport = 'n',
    /// Save Cursor Position (SCP)
    SaveCursorPosition = 's',
    /// Restore Cursor Position (RCP)
    RestoreCursorPosition = 'u',
};

pub fn isCSI(n: u8) bool {
    return (n >= 'A' and n <= 'K') or
        (n == 'S' or n == 'T') or
        (n == 'f' or n == 'm' or n == 'n' or n == 's' or n == 'u');
}

pub const OSC = enum(u8) {
    /// Set icon name and window title
    SetIconAndWindowTitle = 0,
    /// Set window title
    SetWindowTitle = 2,
    /// Set X property on top-level window
    SetXProperty = 3,
    /// Set foreground color
    SetForegroundColor = 10,
    /// Set background color
    SetBackgroundColor = 11,
    /// Set text cursor color
    SetCursorColor = 12,
    /// Set mouse foreground color
    SetMouseForegroundColor = 13,
    /// Set mouse background color
    SetMouseBackgroundColor = 14,
    /// Set highlight color
    SetHighlightColor = 17,
    /// Set hyperlink
    SetHyperlink = 8,
    /// Set current directory
    SetCurrentDirectory = 7,
    /// Set clipboard
    SetClipboard = 52,
};
