const std = @import("std");
const c = @import("c.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const xlib = @import("x.zig");
const Atlas = @import("atlas.zig");

// MAYBE SWITCH TO PANGO + CAIRO?????

//TODO: batch, xcb_render_add_glyphs, text_atlas,cache

const TextCacheEntry = struct {
    text: []u32,
    pixmap: c.xcb_pixmap_t,
    width: u16,
    height: u16,
};
pub const XcbftError = error{
    FontConfigInitFailed,
    ConfigSubstitutionFailed,
    NoFontMatch,
    FreeTypeInitFailed,
    FontFileNotFound,
    FontResourceError,
    FontUnknownFormat,
    FontEmptyFace,
    CharSizeError,
    XrmDatabaseError,
    PictureCreationFailed,
    MemoryAllocationFailed,
    OutOfMemory,
};

pub fn get_drawable_size(conn: *c.xcb_connection_t, drawable: c.xcb_drawable_t) c.xcb_rectangle_t {
    const cookie = c.xcb_get_geometry(conn, drawable);
    // var e: *c.xcb_generic_error_t = undefined;
    var sizes: c.xcb_rectangle_t = undefined;
    // xlib.XlibTerminal.testCookie(cookie, conn, "cannot get geometry");
    const geometry = c.xcb_get_geometry_reply(conn, cookie, null);
    defer std.c.free(geometry);
    sizes.width = geometry.*.width;
    sizes.height = geometry.*.height;
    sizes.x = geometry.*.x;
    sizes.y = geometry.*.y;
    return sizes;
}

pub const Property = enum { // just for ref
    family,
    style,
    slant,
    weight,
    size,
    aspect,
    pixel_size,
    spacing,
    foundry,
    antialias,
    hinting,
    hint_style,
    vertical_layout,
    autohint,
    global_advance,
    width,
    file,
    index,
    ft_face,
    rasterizer,
    outline,
    scalable,
    color,
    variable,
    scale,
    symbol,
    dpi,
    rgba,
    minspace,
    source,
    charset,
    lang,
    fontversion,
    fullname,
    familylang,
    stylelang,
    fullnamelang,
    capability,
    embolden,
    embedded_bitmap,
    decorative,
    lcd_filter,
    font_features,
    font_variations,
    namelang,
    prgname,
    hash,
    postscript_name,
    font_has_hint,
    order,
};

pub fn getPixelSize(pattern: *Pattern, dpi: f64) f64 {
    var max_pixel_size: f64 = 0;
    const pixel_size_val = pattern.get("pixelsize", 0) orelse {
        std.log.debug("Font has no pixel size, using default based on DPI: {}", .{dpi});
        return (12.0 * dpi) / 96.0; // Scale default pixel size by DPI relative to 96
    };
    const pixel_size = switch (pixel_size_val) {
        .double => |d| d,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => {
            std.log.debug("Invalid pixel size type, using default based on DPI: {}", .{dpi});
            return (12.0 * dpi) / 96.0;
        },
    };
    if (pixel_size > max_pixel_size) {
        max_pixel_size = pixel_size;
    }

    // Validate pixel size to prevent unreasonably large values
    const adjusted_pixel_size = if (max_pixel_size > 0) max_pixel_size else (12.0 * dpi) / 96.0;
    if (adjusted_pixel_size > 72.0) { // Cap at 72 pixels (arbitrary but reasonable for terminals)
        std.log.warn("Pixel size {d} too large, clamping to 72.0", .{adjusted_pixel_size});
        return 72.0;
    }
    if (adjusted_pixel_size < 6.0) { // Ensure minimum size for readability
        std.log.warn("Pixel size {d} too small, setting to 6.0", .{adjusted_pixel_size});
        return 6.0;
    }

    // std.log.debug("Using pixel size: {d}", .{adjusted_pixel_size});
    return adjusted_pixel_size;
}
pub fn createTextPixmap(
    conn: *c.xcb_connection_t,
    font: *XRenderFont,
    text: []const u32,
    text_color: c.xcb_render_color_t,
    bg_color: c.xcb_render_color_t,
    pattern: *Pattern,
    visualData: xlib.VisualData,
) !c.xcb_pixmap_t {
    if (c.xcb_connection_has_error(conn) != 0) {
        std.log.err("XCB connection error", .{});
        return XcbftError.XrmDatabaseError;
    }

    const pixel_size = getPixelSize(pattern, font.dpi);
    // Compute dimensions based on actual glyph metrics
    var total_width: f64 = 0;
    var max_height: f64 = 0;
    for (text) |codepoint| {
        if (font.ft.getCharIndex(codepoint)) |glyph_index| {
            try font.ft.loadGlyph(glyph_index, c.FT_LOAD_DEFAULT);
            const advance_x = @as(f64, @floatFromInt(font.ft.face.?.*.glyph.*.advance.x)) / 64.0;
            const bitmap_height = @as(f64, @floatFromInt(font.ft.face.?.*.glyph.*.bitmap.rows));
            total_width += advance_x;
            max_height = @max(max_height, bitmap_height);
        } else {
            // Fallback: estimate advance based on pixel_size
            total_width += pixel_size * 0.6; // Approximate average character width
            max_height = @max(max_height, pixel_size);
        }
    }

    // Add padding
    const width: u16 = @intFromFloat(total_width + pixel_size * 0.4);
    const height: u16 = @intFromFloat(max_height + pixel_size * 0.4);
    std.log.debug("Creating pixmap: width={d}, height={d}, pixel_size={d}", .{ width, height, pixel_size });

    const pmap = c.xcb_generate_id(conn);
    _ = c.xcb_create_pixmap(conn, visualData.visual_depth, pmap, xlib.get_main_window(conn), width, height);
    const bg_uint32 = xcb_color_to_uint32(bg_color);
    const values = [_]u32{ bg_uint32 | 0xff000000, 0 };
    const gc = c.xcb_generate_id(conn);

    _ = c.xcb_change_gc(
        conn,
        gc,
        c.XCB_GC_FOREGROUND | c.XCB_GC_GRAPHICS_EXPOSURES,
        &values,
    );
    const rect = c.xcb_rectangle_t{ .x = 0, .y = 0, .width = width, .height = height };
    _ = c.xcb_poly_fill_rectangle(conn, pmap, gc, 1, &rect);

    // Render text
    const x: i16 = @intFromFloat(0.2 * pixel_size);
    const y: i16 = @intFromFloat(0.2 * pixel_size + pixel_size);

    const advance = try font.drawText(
        pmap,
        x,
        y,
        text[0..],
        text_color,
    );

    // Resize pixmap to fit actual advance
    const final_width: u16 = @intFromFloat(@as(f64, @floatFromInt(advance.x)) + pixel_size * 0.4);
    const resize_pmap = c.xcb_generate_id(conn);
    _ = c.xcb_create_pixmap(conn, visualData.visual_depth, resize_pmap, xlib.get_main_window(conn), final_width, height);
    _ = c.xcb_copy_area(
        conn,
        pmap,
        resize_pmap,
        gc,
        0,
        0,
        0,
        0,
        final_width,
        height,
    );

    _ = c.xcb_free_pixmap(conn, pmap);
    _ = c.xcb_free_gc(conn, gc);
    return resize_pmap;
}
/// Compute (a*b)/0x10000 with maximum accuracy. Its main use is to multiply
/// a given value by a 16.16 fixed-point factor.
pub fn mulFix(a: i32, b: i32) i32 {
    return @intCast(c.FT_MulFix(a, b));
}

pub const UtfHolder = extern struct {
    str: [*]const u32,
    length: u32,
};

// Inspired by https://www.codeproject.com/Articles/1202772/Color-Topics-for-Programmers
pub inline fn xcb_color_to_uint32(rgb: c.xcb_render_color_t) u32 {
    const r = @as(u8, @intCast(rgb.red >> 8)); // 16-bit to 8-bit
    const g = @as(u8, @intCast(rgb.green >> 8));
    const b = @as(u8, @intCast(rgb.blue >> 8));
    const a = @as(u8, @intCast(rgb.alpha >> 8));

    return (@as(u32, a) << 24) |
        (@as(u32, r) << 16) |
        (@as(u32, g) << 8) |
        (@as(u32, b));
}
pub fn intToError(err: c_int) !void {
    return switch (err) {
        c.FT_Err_Ok => {},
        c.FT_Err_Cannot_Open_Resource => error.CannotOpenResource,
        c.FT_Err_Unknown_File_Format => error.UnknownFileFormat,
        c.FT_Err_Invalid_File_Format => error.InvalidFileFormat,
        c.FT_Err_Invalid_Version => error.InvalidVersion,
        c.FT_Err_Lower_Module_Version => error.LowerModuleVersion,
        c.FT_Err_Invalid_Argument => error.InvalidArgument,
        c.FT_Err_Unimplemented_Feature => error.UnimplementedFeature,
        c.FT_Err_Invalid_Table => error.InvalidTable,
        c.FT_Err_Invalid_Offset => error.InvalidOffset,
        c.FT_Err_Array_Too_Large => error.ArrayTooLarge,
        c.FT_Err_Missing_Module => error.MissingModule,
        c.FT_Err_Missing_Property => error.MissingProperty,
        c.FT_Err_Invalid_Glyph_Index => error.InvalidGlyphIndex,
        c.FT_Err_Invalid_Character_Code => error.InvalidCharacterCode,
        c.FT_Err_Invalid_Glyph_Format => error.InvalidGlyphFormat,
        c.FT_Err_Cannot_Render_Glyph => error.CannotRenderGlyph,
        c.FT_Err_Invalid_Outline => error.InvalidOutline,
        c.FT_Err_Invalid_Composite => error.InvalidComposite,
        c.FT_Err_Too_Many_Hints => error.TooManyHints,
        c.FT_Err_Invalid_Pixel_Size => error.InvalidPixelSize,
        c.FT_Err_Invalid_Handle => error.InvalidHandle,
        c.FT_Err_Invalid_Library_Handle => error.InvalidLibraryHandle,
        c.FT_Err_Invalid_Driver_Handle => error.InvalidDriverHandle,
        c.FT_Err_Invalid_Face_Handle => error.InvalidFaceHandle,
        c.FT_Err_Invalid_Size_Handle => error.InvalidSizeHandle,
        c.FT_Err_Invalid_Slot_Handle => error.InvalidSlotHandle,
        c.FT_Err_Invalid_CharMap_Handle => error.InvalidCharMapHandle,
        c.FT_Err_Invalid_Cache_Handle => error.InvalidCacheHandle,
        c.FT_Err_Invalid_Stream_Handle => error.InvalidStreamHandle,
        c.FT_Err_Too_Many_Drivers => error.TooManyDrivers,
        c.FT_Err_Too_Many_Extensions => error.TooManyExtensions,
        c.FT_Err_Out_Of_Memory => error.OutOfMemory,
        c.FT_Err_Unlisted_Object => error.UnlistedObject,
        c.FT_Err_Cannot_Open_Stream => error.CannotOpenStream,
        c.FT_Err_Invalid_Stream_Seek => error.InvalidStreamSeek,
        c.FT_Err_Invalid_Stream_Skip => error.InvalidStreamSkip,
        c.FT_Err_Invalid_Stream_Read => error.InvalidStreamRead,
        c.FT_Err_Invalid_Stream_Operation => error.InvalidStreamOperation,
        c.FT_Err_Invalid_Frame_Operation => error.InvalidFrameOperation,
        c.FT_Err_Nested_Frame_Access => error.NestedFrameAccess,
        c.FT_Err_Invalid_Frame_Read => error.InvalidFrameRead,
        c.FT_Err_Raster_Uninitialized => error.RasterUninitialized,
        c.FT_Err_Raster_Corrupted => error.RasterCorrupted,
        c.FT_Err_Raster_Overflow => error.RasterOverflow,
        c.FT_Err_Raster_Negative_Height => error.RasterNegativeHeight,
        c.FT_Err_Too_Many_Caches => error.TooManyCaches,
        c.FT_Err_Invalid_Opcode => error.InvalidOpcode,
        c.FT_Err_Too_Few_Arguments => error.TooFewArguments,
        c.FT_Err_Stack_Overflow => error.StackOverflow,
        c.FT_Err_Code_Overflow => error.CodeOverflow,
        c.FT_Err_Bad_Argument => error.BadArgument,
        c.FT_Err_Divide_By_Zero => error.DivideByZero,
        c.FT_Err_Invalid_Reference => error.InvalidReference,
        c.FT_Err_Debug_OpCode => error.DebugOpCode,
        c.FT_Err_ENDF_In_Exec_Stream => error.ENDFInExecStream,
        c.FT_Err_Nested_DEFS => error.NestedDEFS,
        c.FT_Err_Invalid_CodeRange => error.InvalidCodeRange,
        c.FT_Err_Execution_Too_Long => error.ExecutionTooLong,
        c.FT_Err_Too_Many_Function_Defs => error.TooManyFunctionDefs,
        c.FT_Err_Too_Many_Instruction_Defs => error.TooManyInstructionDefs,
        c.FT_Err_Table_Missing => error.TableMissing,
        c.FT_Err_Horiz_Header_Missing => error.HorizHeaderMissing,
        c.FT_Err_Locations_Missing => error.LocationsMissing,
        c.FT_Err_Name_Table_Missing => error.NameTableMissing,
        c.FT_Err_CMap_Table_Missing => error.CMapTableMissing,
        c.FT_Err_Hmtx_Table_Missing => error.HmtxTableMissing,
        c.FT_Err_Post_Table_Missing => error.PostTableMissing,
        c.FT_Err_Invalid_Horiz_Metrics => error.InvalidHorizMetrics,
        c.FT_Err_Invalid_CharMap_Format => error.InvalidCharMapFormat,
        c.FT_Err_Invalid_PPem => error.InvalidPPem,
        c.FT_Err_Invalid_Vert_Metrics => error.InvalidVertMetrics,
        c.FT_Err_Could_Not_Find_Context => error.CouldNotFindContext,
        c.FT_Err_Invalid_Post_Table_Format => error.InvalidPostTableFormat,
        c.FT_Err_Invalid_Post_Table => error.InvalidPostTable,
        // c.FT_Err_Syntax_error => error.Syntax,
        c.FT_Err_Stack_Underflow => error.StackUnderflow,
        c.FT_Err_Ignore => error.Ignore,
        c.FT_Err_No_Unicode_Glyph_Name => error.NoUnicodeGlyphName,
        c.FT_Err_Missing_Startfont_Field => error.MissingStartfontField,
        c.FT_Err_Missing_Font_Field => error.MissingFontField,
        c.FT_Err_Missing_Size_Field => error.MissingSizeField,
        c.FT_Err_Missing_Fontboundingbox_Field => error.MissingFontboundingboxField,
        c.FT_Err_Missing_Chars_Field => error.MissingCharsField,
        c.FT_Err_Missing_Startchar_Field => error.MissingStartcharField,
        c.FT_Err_Missing_Encoding_Field => error.MissingEncodingField,
        c.FT_Err_Missing_Bbx_Field => error.MissingBbxField,
        c.FT_Err_Bbx_Too_Big => error.BbxTooBig,
        c.FT_Err_Corrupted_Font_Header => error.CorruptedFontHeader,
        c.FT_Err_Corrupted_Font_Glyphs => error.CorruptedFontGlyphs,
        else => error.UnknownFreetypeError,
    };
}

pub fn errorToInt(err: anytype) c_int {
    return switch (err) {
        error.CannotOpenResource => c.FT_Err_Cannot_Open_Resource,
        error.UnknownFileFormat => c.FT_Err_Unknown_File_Format,
        error.InvalidFileFormat => c.FT_Err_Invalid_File_Format,
        error.InvalidVersion => c.FT_Err_Invalid_Version,
        error.LowerModuleVersion => c.FT_Err_Lower_Module_Version,
        error.InvalidArgument => c.FT_Err_Invalid_Argument,
        error.UnimplementedFeature => c.FT_Err_Unimplemented_Feature,
        error.InvalidTable => c.FT_Err_Invalid_Table,
        error.InvalidOffset => c.FT_Err_Invalid_Offset,
        error.ArrayTooLarge => c.FT_Err_Array_Too_Large,
        error.MissingModule => c.FT_Err_Missing_Module,
        error.MissingProperty => c.FT_Err_Missing_Property,
        error.InvalidGlyphIndex => c.FT_Err_Invalid_Glyph_Index,
        error.InvalidCharacterCode => c.FT_Err_Invalid_Character_Code,
        error.InvalidGlyphFormat => c.FT_Err_Invalid_Glyph_Format,
        error.CannotRenderGlyph => c.FT_Err_Cannot_Render_Glyph,
        error.InvalidOutline => c.FT_Err_Invalid_Outline,
        error.InvalidComposite => c.FT_Err_Invalid_Composite,
        error.TooManyHints => c.FT_Err_Too_Many_Hints,
        error.InvalidPixelSize => c.FT_Err_Invalid_Pixel_Size,
        error.InvalidHandle => c.FT_Err_Invalid_Handle,
        error.InvalidLibraryHandle => c.FT_Err_Invalid_Library_Handle,
        error.InvalidDriverHandle => c.FT_Err_Invalid_Driver_Handle,
        error.InvalidFaceHandle => c.FT_Err_Invalid_Face_Handle,
        error.InvalidSizeHandle => c.FT_Err_Invalid_Size_Handle,
        error.InvalidSlotHandle => c.FT_Err_Invalid_Slot_Handle,
        error.InvalidCharMapHandle => c.FT_Err_Invalid_CharMap_Handle,
        error.InvalidCacheHandle => c.FT_Err_Invalid_Cache_Handle,
        error.InvalidStreamHandle => c.FT_Err_Invalid_Stream_Handle,
        error.TooManyDrivers => c.FT_Err_Too_Many_Drivers,
        error.TooManyExtensions => c.FT_Err_Too_Many_Extensions,
        error.OutOfMemory => c.FT_Err_Out_Of_Memory,
        error.UnlistedObject => c.FT_Err_Unlisted_Object,
        error.CannotOpenStream => c.FT_Err_Cannot_Open_Stream,
        error.InvalidStreamSeek => c.FT_Err_Invalid_Stream_Seek,
        error.InvalidStreamSkip => c.FT_Err_Invalid_Stream_Skip,
        error.InvalidStreamRead => c.FT_Err_Invalid_Stream_Read,
        error.InvalidStreamOperation => c.FT_Err_Invalid_Stream_Operation,
        error.InvalidFrameOperation => c.FT_Err_Invalid_Frame_Operation,
        error.NestedFrameAccess => c.FT_Err_Nested_Frame_Access,
        error.InvalidFrameRead => c.FT_Err_Invalid_Frame_Read,
        error.RasterUninitialized => c.FT_Err_Raster_Uninitialized,
        error.RasterCorrupted => c.FT_Err_Raster_Corrupted,
        error.RasterOverflow => c.FT_Err_Raster_Overflow,
        error.RasterNegativeHeight => c.FT_Err_Raster_Negative_Height,
        error.TooManyCaches => c.FT_Err_Too_Many_Caches,
        error.InvalidOpcode => c.FT_Err_Invalid_Opcode,
        error.TooFewArguments => c.FT_Err_Too_Few_Arguments,
        error.StackOverflow => c.FT_Err_Stack_Overflow,
        error.CodeOverflow => c.FT_Err_Code_Overflow,
        error.BadArgument => c.FT_Err_Bad_Argument,
        error.DivideByZero => c.FT_Err_Divide_By_Zero,
        error.InvalidReference => c.FT_Err_Invalid_Reference,
        error.DebugOpCode => c.FT_Err_Debug_OpCode,
        error.ENDFInExecStream => c.FT_Err_ENDF_In_Exec_Stream,
        error.NestedDEFS => c.FT_Err_Nested_DEFS,
        error.InvalidCodeRange => c.FT_Err_Invalid_CodeRange,
        error.ExecutionTooLong => c.FT_Err_Execution_Too_Long,
        error.TooManyFunctionDefs => c.FT_Err_Too_Many_Function_Defs,
        error.TooManyInstructionDefs => c.FT_Err_Too_Many_Instruction_Defs,
        error.TableMissing => c.FT_Err_Table_Missing,
        error.HorizHeaderMissing => c.FT_Err_Horiz_Header_Missing,
        error.LocationsMissing => c.FT_Err_Locations_Missing,
        error.NameTableMissing => c.FT_Err_Name_Table_Missing,
        error.CMapTableMissing => c.FT_Err_CMap_Table_Missing,
        error.HmtxTableMissing => c.FT_Err_Hmtx_Table_Missing,
        error.PostTableMissing => c.FT_Err_Post_Table_Missing,
        error.InvalidHorizMetrics => c.FT_Err_Invalid_Horiz_Metrics,
        error.InvalidCharMapFormat => c.FT_Err_Invalid_CharMap_Format,
        error.InvalidPPem => c.FT_Err_Invalid_PPem,
        error.InvalidVertMetrics => c.FT_Err_Invalid_Vert_Metrics,
        error.CouldNotFindContext => c.FT_Err_Could_Not_Find_Context,
        error.InvalidPostTableFormat => c.FT_Err_Invalid_Post_Table_Format,
        error.InvalidPostTable => c.FT_Err_Invalid_Post_Table,
        error.Syntax => c.FT_Err_Syntax_error,
        error.StackUnderflow => c.FT_Err_Stack_Underflow,
        error.Ignore => c.FT_Err_Ignore,
        error.NoUnicodeGlyphName => c.FT_Err_No_Unicode_Glyph_Name,
        error.MissingStartfontField => c.FT_Err_Missing_Startfont_Field,
        error.MissingFontField => c.FT_Err_Missing_Font_Field,
        error.MissingSizeField => c.FT_Err_Missing_Size_Field,
        error.MissingFontboundingboxField => c.FT_Err_Missing_Fontboundingbox_Field,
        error.MissingCharsField => c.FT_Err_Missing_Chars_Field,
        error.MissingStartcharField => c.FT_Err_Missing_Startchar_Field,
        error.MissingEncodingField => c.FT_Err_Missing_Encoding_Field,
        error.MissingBbxField => c.FT_Err_Missing_Bbx_Field,
        error.BbxTooBig => c.FT_Err_Bbx_Too_Big,
        error.CorruptedFontHeader => c.FT_Err_Corrupted_Font_Header,
        error.CorruptedFontGlyphs => c.FT_Err_Corrupted_Font_Glyphs,
    };
}

pub const CharSet = opaque {
    pub fn create() *CharSet {
        return @ptrCast(c.FcCharSetCreate());
    }

    pub fn destroy(self: *CharSet) void {
        c.FcCharSetDestroy(self.cval());
    }

    pub fn addChar(self: *CharSet, cp: u32) bool {
        return c.FcCharSetAddChar(self.cval(), cp) == c.FcTrue;
    }

    pub fn hasChar(self: *const CharSet, cp: u32) bool {
        return c.FcCharSetHasChar(self.cvalConst(), cp) == c.FcTrue;
    }

    pub inline fn cval(self: *Pattern) *c.FcPattern {
        return @ptrCast(self);
    }
    pub inline fn cvalConst(self: *const CharSet) *const c.struct__FcCharSet {
        return @ptrCast(self);
    }
};

pub const Pattern = opaque {
    pub fn create() *Pattern {
        return @ptrCast(c.FcPatternCreate());
    }

    pub fn parse(str: [*c]const u8) *Pattern {
        return @ptrCast(c.FcNameParse(str));
    }

    pub fn destroy(self: *Pattern) void {
        c.FcPatternDestroy(self.cval());
    }

    pub fn defaultSubstitute(self: *Pattern) void {
        c.FcDefaultSubstitute(self.cval());
    }

    pub fn print(self: *Pattern) void {
        c.FcPatternPrint(self.cval());
    }

    pub fn add(self: *Pattern, prop: []const u8, value: Value, append: bool) bool {
        return c.FcPatternAdd(
            self.cval(),
            prop.ptr,
            value.cval(),
            if (append) c.FcTrue else c.FcFalse,
        ) == c.FcTrue;
    }

    pub fn get(self: *Pattern, prop: []const u8, id: u32) ?Value {
        var val: c.FcValue = undefined;
        const result = c.FcPatternGet(self.cval(), prop.ptr, @intCast(id), &val);
        if (result != c.FcResultMatch) return null;
        return Value.init(&val);
    }

    pub fn duplicate(self: *Pattern) !*Pattern {
        const new_pattern = c.FcPatternDuplicate(self.cval());
        if (new_pattern == null) return XcbftError.MemoryAllocationFailed;
        return @ptrCast(new_pattern);
    }

    pub inline fn cval(self: *Pattern) *c.struct__FcPattern {
        return @ptrCast((self));
    }
};

pub const Value = union(enum) {
    string: [:0]const u8,
    double: f64,
    integer: i32,
    bool: bool,

    pub fn init(cvalue: *c.FcValue) Value {
        return switch (cvalue.type) {
            c.FcTypeString => .{ .string = std.mem.sliceTo(cvalue.u.s, 0) },
            c.FcTypeDouble => .{ .double = cvalue.u.d },
            c.FcTypeInteger => .{ .integer = @intCast(cvalue.u.i) },
            c.FcTypeBool => .{ .bool = cvalue.u.b == c.FcTrue },
            else => unreachable,
        };
    }

    pub fn cval(self: Value) c.FcValue {
        return .{
            .type = switch (self) {
                .string => c.FcTypeString,
                .double => c.FcTypeDouble,
                .integer => c.FcTypeInteger,
                .bool => c.FcTypeBool,
            },
            .u = switch (self) {
                .string => |v| .{ .s = v.ptr },
                .double => |v| .{ .d = v },
                .integer => |v| .{ .i = v },
                .bool => |v| .{ .b = if (v) c.FcTrue else c.FcFalse },
            },
        };
    }
};

pub const Descriptor = struct {
    family: ?[:0]const u8 = null,
    size: f32 = 0,
    codepoint: u32 = 0,

    pub fn toFcPattern(self: Descriptor) *Pattern {
        const pat = Pattern.create();
        if (self.family) |family| {
            _ = pat.add("family", .{ .string = family }, false);
        }
        if (self.size > 0) {
            _ = pat.add("pixelsize", .{ .double = self.size }, false);
        }
        if (self.codepoint > 0) {
            const cs = CharSet.create();
            defer cs.destroy();
            _ = cs.addChar(self.codepoint);
            _ = pat.add("charset", .{ .char_set = cs }, false);
        }
        return pat;
    }
};

pub const Fontconfig = struct {
    fc_config: *c.FcConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Fontconfig {
        if (c.FcInit() == c.FcFalse) {
            return XcbftError.FontConfigInitFailed;
        }
        return .{ .fc_config = c.FcInitLoadConfigAndFonts().?, .allocator = allocator };
    }

    pub fn deinit(self: *Fontconfig) void {
        c.FcConfigDestroy(self.fc_config);
        c.FcFini();
    }

    pub fn queryFont(_: *Fontconfig, fontquery: [:0]const u8) !?*Pattern {
        const fc_pattern = c.FcNameParse(fontquery.ptr);
        if (fc_pattern == null) return null;

        c.FcDefaultSubstitute(fc_pattern);
        if (c.FcConfigSubstitute(null, fc_pattern, c.FcMatchPattern) == c.FcFalse) {
            c.FcPatternDestroy(fc_pattern);
            return XcbftError.ConfigSubstitutionFailed;
        }

        var result: c.FcResult = undefined;
        const pat_output = c.FcFontMatch(null, fc_pattern, &result);
        c.FcPatternDestroy(fc_pattern);

        if (result == c.FcResultMatch) {
            return @ptrCast(pat_output);
        } else {
            return XcbftError.NoFontMatch;
        }
    }

    pub fn queryByCharSupport(self: *Fontconfig, character: u32, copy_pattern: ?*Pattern, dpi: f64) !FreeType {
        const charset = c.FcCharSetCreate() orelse return XcbftError.MemoryAllocationFailed;
        defer c.FcCharSetDestroy(charset);
        _ = c.FcCharSetAddChar(charset, character);

        const charset_pattern = if (copy_pattern) |pat| c.FcPatternDuplicate(pat.cval()) else c.FcPatternCreate();
        if (charset_pattern == null) return XcbftError.MemoryAllocationFailed;
        defer c.FcPatternDestroy(charset_pattern);

        _ = c.FcPatternAddCharSet(charset_pattern, c.FC_CHARSET, charset);
        _ = c.FcPatternAddBool(charset_pattern, c.FC_SCALABLE, c.FcTrue);

        c.FcDefaultSubstitute(charset_pattern);
        if (c.FcConfigSubstitute(null, charset_pattern, c.FcMatchPattern) == c.FcFalse) {
            return XcbftError.ConfigSubstitutionFailed;
        }
        var result: c.FcResult = undefined;

        const pat_output = c.FcFontMatch(null, charset_pattern, &result);
        if (result != c.FcResultMatch) {
            return XcbftError.NoFontMatch;
        }
        defer c.FcPatternDestroy(pat_output);

        return try FreeType.loadFace(self.allocator, @ptrCast(pat_output), dpi);
    }
};

pub const FreeType = struct {
    library: c.FT_Library,
    face: ?c.FT_Face,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !FreeType {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != c.FT_Err_Ok) {
            std.log.err("Could not initialize FreeType", .{});
            return XcbftError.FreeTypeInitFailed;
        }

        return .{ .library = library, .face = null, .allocator = allocator };
    }

    pub fn deinit(self: *FreeType) void {
        if (self.face) |f| _ = c.FT_Done_Face(f);

        _ = c.FT_Done_FreeType(self.library);
    }
    pub fn loadFace(
        allocator: Allocator,
        pattern: *Pattern,
        dpi: f64,
    ) !FreeType {
        var ft = try FreeType.init(allocator);

        // if (pattern == null) return XcbftError.NoFontMatch;

        var fc_file: c.FcValue = undefined;
        var result = c.FcPatternGet(pattern.cval(), c.FC_FILE, 0, &fc_file);
        if (result != c.FcResultMatch) {
            std.log.err("Font has no file location", .{});
            return XcbftError.FontFileNotFound;
        }

        var fc_index: c.FcValue = undefined;
        result = c.FcPatternGet(pattern.cval(), c.FC_INDEX, 0, &fc_index);
        const index = if (result != c.FcResultMatch) 0 else fc_index.u.i;

        var face: c.FT_Face = undefined;
        try intToError(c.FT_New_Face(ft.library, fc_file.u.s, index, &face));

        var fc_matrix: c.FcValue = undefined;
        result = c.FcPatternGet(pattern.cval(), c.FC_MATRIX, 0, &fc_matrix);
        if (result == c.FcResultMatch) {
            const ft_matrix = c.FT_Matrix{
                .xx = @as(c.FT_Fixed, @intFromFloat(fc_matrix.u.m.*.xx * 0x10000)),
                .xy = @as(c.FT_Fixed, @intFromFloat(fc_matrix.u.m.*.xy * 0x10000)),
                .yx = @as(c.FT_Fixed, @intFromFloat(fc_matrix.u.m.*.yx * 0x10000)),
                .yy = @as(c.FT_Fixed, @intFromFloat(fc_matrix.u.m.*.yy * 0x10000)),
            };
            c.FT_Set_Transform(face, @constCast(@ptrCast(&ft_matrix)), null);
        }

        var fc_pixel_size: c.FcValue = undefined;
        result = c.FcPatternGet(pattern.cval(), c.FC_PIXEL_SIZE, 0, &fc_pixel_size);
        // const pixel_size = if (result != c.FcResultMatch or fc_pixel_size.u.d == 0) 12.0 else fc_pixel_size.u.d;
        const pixel_size = getPixelSize(pattern, dpi);

        const char_size = pixel_size * 64.0;
        const dpi_uint: c.FT_UInt = @intFromFloat(dpi);
        // std.log.info("Setting char_size: {d}, dpi: {}", .{ @as(u32, @intFromFloat(char_size / 64)), dpi_uint });
        try intToError(c.FT_Set_Char_Size(
            face,
            0,
            @intFromFloat(char_size),
            dpi_uint,
            dpi_uint,
        ));

        ft.face = face;

        return ft;
    }

    pub fn getCharIndex(self: *FreeType, char: u32) ?u32 {
        if (self.face == null) return null;
        const index = c.FT_Get_Char_Index(self.face.?, char);
        if (index != 0) return index;
        return null;
    }

    pub fn loadGlyph(self: *FreeType, glyph_index: u32, flags: c_int) !void {
        if (self.face == null) return XcbftError.FontEmptyFace;
        try intToError(c.FT_Load_Glyph(self.face.?, glyph_index, flags));
    }

    pub fn renderGlyph(self: *FreeType, render_mode: c.FT_Render_Mode) !void {
        if (self.face == null) return XcbftError.FontEmptyFace;
        try intToError(c.FT_Render_Glyph(self.face.?.*.glyph, render_mode));
    }
};
pub const FontSet = opaque {
    pub fn create() *FontSet {
        return @ptrCast(c.FcFontSetCreate());
    }

    pub fn destroy(self: *FontSet) void {
        c.FcFontSetDestroy(self.cval());
    }

    pub fn fonts(self: *FontSet) []*Pattern {
        const empty: [0]*Pattern = undefined;
        const s = self.cval();
        if (s.fonts == null) return &empty;
        const ptr: [*]*Pattern = @ptrCast(@alignCast(s.fonts));
        const len: usize = @intCast(s.nfont);
        return ptr[0..len];
    }

    pub fn add(self: *FontSet, pat: *Pattern) bool {
        return c.FcFontSetAdd(self.cval(), pat.cval()) == c.FcTrue;
    }

    pub fn print(self: *FontSet) void {
        c.FcFontSetPrint(self.cval());
    }

    pub inline fn cval(self: *FontSet) *c.struct__FcFontSet {
        return @ptrCast(@alignCast(self));
    }
};

test "create fontset" {
    var fs = FontSet.create();
    defer fs.destroy();

    try testing.expectEqual(@as(usize, 0), fs.fonts().len);
}

pub const XRenderFont = struct {
    conn: *c.xcb_connection_t,
    pattern: *Pattern,
    ft: FreeType,
    glyphsets: std.AutoHashMap(u32, c.xcb_render_glyphset_t),
    allocator: Allocator,
    dpi: f64,
    atlas: Atlas,
    glyph_regions: std.AutoHashMap(u32, GlyphInfo),
    // GlyphInfo stores atlas region and metrics
    const GlyphInfo = struct {
        region: ?Atlas.Region, // null for glyphs with no bitmap (e.g., space)
        bitmap_left: i32,
        bitmap_top: i32,
        advance_x: i32,
        advance_y: i32,
        from_fallback: bool, // Track if from fallback font
    };

    const Self = @This();

    pub fn init(
        conn: *c.xcb_connection_t,
        allocator: Allocator,
        fontquery: [:0]const u8,
    ) !Self {
        var fc = try Fontconfig.init(allocator);
        defer fc.deinit();

        const pattern = try fc.queryFont(fontquery) orelse {
            std.log.err("font not found: {s}", .{fontquery});
            return error.NoFontMatch;
        };

        const dpi = try getDpi(conn);
        const ft = try FreeType.loadFace(allocator, pattern, dpi);

        const atlas = try Atlas.init(allocator, 512, .grayscale);
        const glyph_regions = std.AutoHashMap(u32, GlyphInfo).init(allocator);

        return .{
            .conn = conn,
            .pattern = pattern,
            .ft = ft,
            .glyphsets = std.AutoHashMap(u32, c.xcb_render_glyphset_t).init(allocator),
            .allocator = allocator,
            .dpi = dpi,
            .atlas = atlas,
            .glyph_regions = glyph_regions,
        };
    }
    pub fn deinit(self: *Self) void {
        var it = self.glyphsets.iterator();
        while (it.next()) |entry| {
            _ = c.xcb_render_free_glyph_set(self.conn, entry.value_ptr.*);
        }
        self.glyphsets.deinit();
        self.pattern.destroy();
        self.ft.deinit();
        self.atlas.deinit(self.allocator);
        self.glyph_regions.deinit();
    }

    fn cacheGlyphs(self: *Self, codepoints: []const u32, face: c.FT_Face, is_fallback: bool) !void {
        _ = c.FT_Select_Charmap(face, c.ft_encoding_unicode);
        var total_width: u32 = 0;
        var max_height: u32 = 0;
        for (codepoints) |codepoint| {
            const glyph_index = c.FT_Get_Char_Index(face, codepoint);
            if (glyph_index == 0) continue;
            try intToError(c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_NORMAL));
            try intToError(c.FT_Render_Glyph(face.*.glyph, c.FT_RENDER_MODE_NORMAL));
            const bitmap = &face.*.glyph.*.bitmap;
            total_width += bitmap.*.width;
            max_height = @max(max_height, bitmap.*.rows);
        }
        const region = self.atlas.reserve(self.allocator, total_width, max_height) catch |err| {
            try self.atlas.grow(self.allocator, self.atlas.size * 2);
            return err;
        };
        var x_offset: u32 = region.x;
        for (codepoints) |codepoint| {
            const glyph_index = c.FT_Get_Char_Index(face, codepoint);
            if (glyph_index == 0) {
                const pixel_size = getPixelSize(self.pattern, self.dpi);
                try self.glyph_regions.put(codepoint, .{
                    .region = null,
                    .bitmap_left = 0,
                    .bitmap_top = 0,
                    .advance_x = @intFromFloat(pixel_size * 0.6),
                    .advance_y = 0,
                    .from_fallback = is_fallback,
                });
                continue;
            }
            try intToError(c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_NORMAL));
            try intToError(c.FT_Render_Glyph(face.*.glyph, c.FT_RENDER_MODE_NORMAL));
            const bitmap = &face.*.glyph.*.bitmap;
            const bitmap_left = face.*.glyph.*.bitmap_left;
            const bitmap_top = face.*.glyph.*.bitmap_top;
            const advance_x = @divTrunc(face.*.glyph.*.advance.x, 64);
            const advance_y = @divTrunc(face.*.glyph.*.advance.y, 64);
            if (bitmap.*.width == 0 or bitmap.*.rows == 0) {
                try self.glyph_regions.put(codepoint, .{
                    .region = null,
                    .bitmap_left = bitmap_left,
                    .bitmap_top = bitmap_top,
                    .advance_x = @intCast(advance_x),
                    .advance_y = @intCast(advance_y),
                    .from_fallback = is_fallback,
                });
                continue;
            }
            const glyph_region = Atlas.Region{
                .x = x_offset,
                .y = region.y,
                .width = bitmap.*.width,
                .height = bitmap.*.rows,
            };
            for (0..bitmap.*.rows) |y| {
                const atlas_offset = (glyph_region.y + y) * self.atlas.size + glyph_region.x;
                const bitmap_offset = y * bitmap.*.width;
                util.copyBytes(
                    u8,
                    self.atlas.data[atlas_offset .. atlas_offset + bitmap.*.width],
                    bitmap.*.buffer[bitmap_offset .. bitmap_offset + bitmap.*.width],
                );
            }
            try self.glyph_regions.put(codepoint, .{
                .region = glyph_region,
                .bitmap_left = bitmap_left,
                .bitmap_top = bitmap_top,
                .advance_x = @intCast(advance_x),
                .advance_y = @intCast(advance_y),
                .from_fallback = is_fallback,
            });
            x_offset += bitmap.*.width;
        }
    }
    pub fn drawText(
        self: *Self,
        pmap: c.xcb_drawable_t,
        x: i16,
        y: i16,
        text: []const u32,
        color: c.xcb_render_color_t,
    ) !c.FT_Vector {
        const geo_cookie = c.xcb_get_geometry(self.conn, pmap);
        const geo_reply = c.xcb_get_geometry_reply(self.conn, geo_cookie, null);
        if (geo_reply == null) {
            std.log.err("cannot get geometry pixmap", .{});
            return error.CannotGetGeometry;
        }
        defer std.c.free(geo_reply);
        const actual_depth = geo_reply.*.depth;
        // std.log.debug("Pixmap depth: {}", .{actual_depth});

        // Filter out non-printable codepoints and invalid Unicode
        var filtered_text = try self.allocator.alloc(u32, text.len);
        defer self.allocator.free(filtered_text);
        var filtered_len: usize = 0;
        for (text) |codepoint| {
            if (codepoint < 0x20 or codepoint > 0x10FFFF) {
                std.log.debug("Skipping invalid or non-printable codepoint: U+{x:0>4}", .{codepoint});
                continue;
            }
            filtered_text[filtered_len] = codepoint;
            filtered_len += 1;
        }

        if (filtered_len == 0) {
            std.log.warn("No printable codepoints to render", .{});
            return c.FT_Vector{ .x = 0, .y = 0 };
        }

        const utf_holder = UtfHolder{ .str = filtered_text.ptr, .length = @intCast(filtered_len) };
        const fmt_rep = c.xcb_render_util_query_formats(self.conn);

        const fmt = switch (actual_depth) {
            24 => c.xcb_render_util_find_standard_format(fmt_rep, c.XCB_PICT_STANDARD_RGB_24),
            32 => c.xcb_render_util_find_standard_format(fmt_rep, c.XCB_PICT_STANDARD_ARGB_32),
            else => {
                std.log.err("unsupported depth pixmap: {}", .{actual_depth});
                return error.UnsupportedDepth;
            },
        };
        const picture: c.xcb_render_picture_t = c.xcb_generate_id(self.conn);
        const poly_mode = c.XCB_RENDER_POLY_MODE_IMPRECISE;
        const poly_edge = c.XCB_RENDER_POLY_EDGE_SMOOTH;
        const values = [2]u32{ poly_mode, poly_edge };
        const cookie = c.xcb_render_create_picture_checked(
            self.conn,
            picture,
            pmap,
            fmt.*.id,
            c.XCB_RENDER_CP_POLY_MODE | c.XCB_RENDER_CP_POLY_EDGE,
            &values,
        );

        if (c.xcb_request_check(self.conn, cookie)) |err| {
            std.log.err("Could not create picture: {}", .{err.*.error_code});
            return error.PictureCreationFailed;
        }
        defer _ = c.xcb_render_free_picture(self.conn, picture);

        const fg_pen = try self.createPen(color);
        defer _ = c.xcb_render_free_picture(self.conn, fg_pen);

        const glyphset_advance = try self.loadGlyphset(utf_holder);

        const ts = c.xcb_render_util_composite_text_stream(glyphset_advance.glyphset, utf_holder.length, 0) orelse
            return error.MemoryAllocationFailed;
        defer c.xcb_render_util_composite_text_free(ts);

        c.xcb_render_util_glyphs_32(ts, x, y, utf_holder.length, utf_holder.str);

        _ = c.xcb_render_util_composite_text(
            self.conn,
            c.XCB_RENDER_PICT_OP_OVER,
            fg_pen,
            picture,
            0,
            0,
            0,
            ts,
        );

        _ = c.xcb_flush(self.conn);
        return glyphset_advance.advance;
    }
    fn createPen(self: *Self, color: c.xcb_render_color_t) !c.xcb_render_picture_t {
        const fmt_rep = c.xcb_render_util_query_formats(self.conn);
        const fmt = c.xcb_render_util_find_standard_format(fmt_rep, c.XCB_PICT_STANDARD_ARGB_32);

        const pm = c.xcb_generate_id(self.conn);
        _ = c.xcb_create_pixmap(self.conn, 32, pm, xlib.get_main_window(self.conn), 1, 1);

        var values = [1]u32{c.XCB_RENDER_REPEAT_NORMAL};
        const picture = c.xcb_generate_id(self.conn);
        _ = c.xcb_render_create_picture(self.conn, picture, pm, fmt.*.id, c.XCB_RENDER_CP_REPEAT, &values);

        const rect = c.xcb_rectangle_t{ .x = 0, .y = 0, .width = 1, .height = 1 };
        _ = c.xcb_render_fill_rectangles(self.conn, c.XCB_RENDER_PICT_OP_OVER, picture, color, 1, &rect);

        _ = c.xcb_free_pixmap(self.conn, pm);
        return picture;
    }

    fn loadGlyphset(self: *Self, text: UtfHolder) !struct { glyphset: c.xcb_render_glyphset_t, advance: c.FT_Vector } {
        var total_advance = c.FT_Vector{ .x = 0, .y = 0 };

        // Use a persistent glyphset based on DPI
        const gs_key = @as(u32, @intFromFloat(self.dpi * 10)); // Unique per DPI
        const gs = if (self.glyphsets.get(gs_key)) |glyphset| glyphset else blk: {
            const fmt_rep = c.xcb_render_util_query_formats(self.conn);
            const fmt_a8 = c.xcb_render_util_find_standard_format(fmt_rep, c.XCB_PICT_STANDARD_A_8);
            if (fmt_a8 == null) return error.NoPictureFormat;
            const new_gs = c.xcb_generate_id(self.conn);
            _ = c.xcb_render_create_glyph_set(self.conn, new_gs, fmt_a8.*.id);
            try self.glyphsets.put(gs_key, new_gs);
            break :blk new_gs;
        };

        // Initialize Fontconfig for fallback fonts
        var fc = try Fontconfig.init(self.allocator);
        defer fc.deinit();

        // Collect unique codepoints
        var codepoints = std.AutoHashMap(u32, void).init(self.allocator);
        defer codepoints.deinit();
        for (0..text.length) |i| {
            const codepoint = text.str[i];
            if (codepoint > 0x10FFFF) {
                std.log.warn("Invalid Unicode codepoint: U+{x:0>4}", .{codepoint});
                continue;
            }
            try codepoints.put(codepoint, {});
        }

        // Cache uncached glyphs
        var uncached = std.ArrayList(u32).init(self.allocator);
        defer uncached.deinit();
        var it = codepoints.keyIterator();
        while (it.next()) |codepoint| {
            if (!self.glyph_regions.contains(codepoint.*)) {
                try uncached.append(codepoint.*);
            }
        }

        if (uncached.items.len > 0) {
            // Cache glyphs from primary font
            try self.cacheGlyphs(uncached.items, self.ft.face.?, false);

            // Handle fallbacks for remaining uncached glyphs
            var fallback_fonts = std.AutoHashMap(u32, FreeType).init(self.allocator);
            defer {
                var fallback_it = fallback_fonts.valueIterator();
                while (fallback_it.next()) |ft| ft.deinit();
                fallback_fonts.deinit();
            }

            var still_uncached = std.ArrayList(u32).init(self.allocator);
            defer still_uncached.deinit();
            for (uncached.items) |codepoint| {
                if (!self.glyph_regions.contains(codepoint)) {
                    try still_uncached.append(codepoint);
                }
            }

            for (still_uncached.items) |codepoint| {
                const fallback_ft = try fc.queryByCharSupport(codepoint, self.pattern, self.dpi);
                const char_size = getPixelSize(self.pattern, self.dpi) * 64.0;
                const dpi_uint: c_uint = @intFromFloat(self.dpi);
                try intToError(c.FT_Set_Char_Size(fallback_ft.face.?, 0, @intFromFloat(char_size), dpi_uint, dpi_uint));
                try self.cacheGlyphs(&[_]u32{codepoint}, fallback_ft.face.?, true);
                try fallback_fonts.put(codepoint, fallback_ft);
            }
        }

        // Precompute total bitmap size for efficiency
        var total_bitmap_size: usize = 0;
        it = codepoints.keyIterator();
        while (it.next()) |codepoint| {
            if (self.glyph_regions.get(codepoint.*).?.region) |region| {
                const stride = (region.width + 3) & ~@as(u32, 3);
                total_bitmap_size += stride * region.height;
            }
        }

        // Prepare glyph data
        var gids = try self.allocator.alloc(u32, codepoints.count());
        defer self.allocator.free(gids);
        var ginfos = try self.allocator.alloc(c.xcb_render_glyphinfo_t, codepoints.count());
        defer self.allocator.free(ginfos);
        var bitmaps = std.ArrayList(u8).init(self.allocator);
        defer bitmaps.deinit();
        try bitmaps.ensureTotalCapacity(total_bitmap_size);

        var index: usize = 0;
        it = codepoints.keyIterator();
        while (it.next()) |codepoint| {
            const glyph_info = self.glyph_regions.get(codepoint.*).?;
            gids[index] = codepoint.*;

            if (glyph_info.region) |region| {
                ginfos[index] = c.xcb_render_glyphinfo_t{
                    .x = @intCast(-glyph_info.bitmap_left),
                    .y = @intCast(glyph_info.bitmap_top),
                    .width = @intCast(region.width),
                    .height = @intCast(region.height),
                    .x_off = @as(i16, @intCast(glyph_info.advance_x)),
                    .y_off = @as(i16, @intCast(glyph_info.advance_y)),
                };

                const stride = (region.width + 3) & ~@as(u32, 3);
                const offset = region.y * self.atlas.size + region.x;
                for (0..region.height) |y| {
                    const src = self.atlas.data[offset + y * self.atlas.size .. offset + y * self.atlas.size + region.width];
                    bitmaps.appendSliceAssumeCapacity(src);
                    for (region.width..stride) |_| {
                        bitmaps.appendAssumeCapacity(0);
                    }
                }
            } else {
                ginfos[index] = c.xcb_render_glyphinfo_t{
                    .x = 0,
                    .y = 0,
                    .width = 0,
                    .height = 0,
                    .x_off = @as(i16, @intCast(glyph_info.advance_x)),
                    .y_off = @as(i16, @intCast(glyph_info.advance_y)),
                };
            }

            total_advance.x += glyph_info.advance_x;
            total_advance.y += glyph_info.advance_y;
            index += 1;
        }

        if (index > 0 and bitmaps.items.len > 0) {
            const cookie = c.xcb_render_add_glyphs_checked(
                self.conn,
                gs,
                @intCast(index),
                gids.ptr,
                ginfos.ptr,
                @intCast(bitmaps.items.len),
                bitmaps.items.ptr,
            );
            if (c.xcb_request_check(self.conn, cookie)) |err| {
                std.log.err("Failed to add glyphs: error_code={}", .{err.*.error_code});
                return error.GlyphAddFailed;
            }
            _ = c.xcb_flush(self.conn);
        }

        return .{ .glyphset = gs, .advance = total_advance };
    }
    pub fn loadGlyph(self: *Self, gs: c.xcb_render_glyphset_t, charcode: u32) !c.FT_Vector {
        if (self.ft.face == null) return error.FontEmptyFace;
        const face = self.ft.face.?;

        _ = c.FT_Select_Charmap(face, c.ft_encoding_unicode);
        const glyph_index = c.FT_Get_Char_Index(face, charcode);
        if (glyph_index == 0) {
            std.log.debug("No glyph found for character U+{x:0>4}", .{charcode});
            const pixel_size = getPixelSize(self.pattern, self.dpi);
            return c.FT_Vector{ .x = @intFromFloat(pixel_size * 0.6), .y = 0 }; // Default advance
        }

        try intToError(c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_NORMAL));
        try intToError(c.FT_Render_Glyph(face.*.glyph, c.FT_RENDER_MODE_NORMAL));

        const bitmap = &face.*.glyph.*.bitmap;
        // Handle space character (U+0020) explicitly
        if (charcode == 0x20 or bitmap.*.width == 0 or bitmap.*.rows == 0) {
            const advance_x = @divTrunc(face.*.glyph.*.advance.x, 64);
            if (charcode == 0x20) {
                // std.log.debug("Space character (U+0020) detected, using advance: {}", .{advance_x});
            } else {
                std.log.debug("Empty bitmap for glyph U+{x:0>4}, using advance: {}", .{ charcode, advance_x });
            }
            return c.FT_Vector{ .x = advance_x, .y = 0 };
        }

        var ginfo = c.xcb_render_glyphinfo_t{
            .x = @intCast(-face.*.glyph.*.bitmap_left),
            .y = @intCast(face.*.glyph.*.bitmap_top),
            .width = @intCast(bitmap.*.width),
            .height = @intCast(bitmap.*.rows),
            .x_off = @as(i16, @intCast(@divTrunc(face.*.glyph.*.advance.x, 64))),
            .y_off = @as(i16, @intCast(@divTrunc(face.*.glyph.*.advance.y, 64))),
        };

        const glyph_advance = c.FT_Vector{ .x = ginfo.x_off, .y = ginfo.y_off };
        const gid = charcode;

        const stride: u32 = (ginfo.width + 3) & ~@as(u32, 3);
        const tmpbitmap = try self.allocator.alignedAlloc(u8, 4, @as(usize, @intCast(stride * ginfo.height)));
        defer self.allocator.free(tmpbitmap);
        @memset(tmpbitmap, 0);

        for (0..@as(usize, @intCast(ginfo.height))) |y| {
            if (bitmap.*.buffer) |buf| {
                util.copyBytes(
                    u8,
                    tmpbitmap[y * @as(usize, @intCast(stride)) ..][0..@as(usize, @intCast(ginfo.width))],
                    buf[@as(usize, @intCast(y * bitmap.*.width))..][0..@as(usize, @intCast(ginfo.width))],
                );
            }
        }

        const cookie = c.xcb_render_add_glyphs_checked(self.conn, gs, 1, &gid, &ginfo, stride * ginfo.height, tmpbitmap.ptr);
        if (c.xcb_request_check(self.conn, cookie)) |err| {
            std.log.err("Failed to add glyph U+{x:0>4}: {}", .{ charcode, err.*.error_code });
            return error.PictureCreationFailed;
        }
        _ = c.xcb_flush(self.conn);

        return glyph_advance;
    }
    fn loadGlyphWithFace(self: *Self, gs: c.xcb_render_glyphset_t, face: c.FT_Face, charcode: u32) !c.FT_Vector {
        _ = c.FT_Select_Charmap(face, c.ft_encoding_unicode);
        const glyph_index = c.FT_Get_Char_Index(face, charcode);
        if (glyph_index == 0) {
            std.log.debug("No glyph found in fallback font for character U+{x:0>4}", .{charcode});
            const pixel_size = getPixelSize(self.pattern, self.dpi);
            return c.FT_Vector{ .x = @intFromFloat(pixel_size * 0.6), .y = 0 };
        }

        try intToError(c.FT_Load_Glyph(face, glyph_index, c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_NORMAL));
        try intToError(c.FT_Render_Glyph(face.*.glyph, c.FT_RENDER_MODE_NORMAL));

        const bitmap = &face.*.glyph.*.bitmap;
        if (bitmap.*.width == 0 or bitmap.*.rows == 0) {
            std.log.debug("Empty bitmap for fallback glyph U+{x:0>4}", .{charcode});
            const pixel_size = getPixelSize(self.pattern, self.dpi);
            return c.FT_Vector{ .x = @intFromFloat(pixel_size * 0.6), .y = 0 };
        }

        var ginfo = c.xcb_render_glyphinfo_t{
            .x = @intCast(-face.*.glyph.*.bitmap_left),
            .y = @intCast(face.*.glyph.*.bitmap_top),
            .width = @intCast(bitmap.*.width),
            .height = @intCast(bitmap.*.rows),
            .x_off = @as(i16, @intCast(@divTrunc(face.*.glyph.*.advance.x, 64))),
            .y_off = @as(i16, @intCast(@divTrunc(face.*.glyph.*.advance.y, 64))),
        };

        const glyph_advance = c.FT_Vector{ .x = ginfo.x_off, .y = ginfo.y_off };
        const gid = charcode;

        const stride: u32 = (ginfo.width + 3) & ~@as(u32, 3);
        const tmpbitmap = try self.allocator.alloc(u8, @as(usize, @intCast(stride * ginfo.height)));
        defer self.allocator.free(tmpbitmap);
        @memset(tmpbitmap, 0);

        for (0..@as(usize, @intCast(ginfo.height))) |y| {
            if (bitmap.*.buffer) |buf| {
                util.copyBytes(
                    u8,
                    tmpbitmap[y * @as(usize, @intCast(stride)) ..][0..@as(usize, @intCast(ginfo.width))],
                    buf[@as(usize, @intCast(y * bitmap.*.width))..][0..@as(usize, @intCast(ginfo.width))],
                );
            }
        }

        const cookie = c.xcb_render_add_glyphs_checked(self.conn, gs, 1, &gid, &ginfo, stride * ginfo.height, tmpbitmap.ptr);
        if (c.xcb_request_check(self.conn, cookie)) |err| {
            std.log.err("Failed to add fallback glyph U+{x:0>4}: {}", .{ charcode, err.*.error_code });
            return error.PictureCreationFailed;
        }
        _ = c.xcb_flush(self.conn);

        return glyph_advance;
    }
};
/// Convert f64 DPI to c_uint for FreeType, ensuring valid range
// fn dpiToUint(dpi: f64) c_uint {
//     if (dpi <= 0) return 96.0; // Default DPI
//     return @intFromFloat(@min(dpi, @as(f64, @floatFromInt(std.math.maxInt(c_uint)))));
// }
// get dpi from x
pub fn getDpi(conn: *c.xcb_connection_t) XcbftError!f64 {
    if (c.xcb_connection_has_error(conn) != 0) {
        std.log.err("XCB connection error", .{});
        return XcbftError.XrmDatabaseError;
    }

    var dpi: f64 = 0;

    // Try XRM database
    const xrm_db = c.xcb_xrm_database_from_default(conn);
    if (xrm_db != null) {
        defer c.xcb_xrm_database_free(xrm_db);
        const ret = c.xcb_xrm_resource_get_long(xrm_db, "Xft.dpi", null, @ptrCast(&dpi));
        if (ret >= 0 and dpi > 0) {
            return dpi;
        } else {
            std.log.debug("XRM resource 'Xft.dpi' not found or invalid (ret={})", .{ret});
            // return 96.0;
        }
    } else {
        std.log.debug("XRM database unavailable", .{});
    }

    // Fallback to screen metrics
    const setup = c.xcb_get_setup(conn);
    if (setup == null) {
        std.log.err("Failed to get XCB setup", .{});
        return XcbftError.XrmDatabaseError;
    }
    dpi = 0;

    var iter = c.xcb_setup_roots_iterator(setup);
    while (iter.rem > 0) {
        if (iter.data != null) {
            const screen = iter.data.*;
            const width_mm = @as(f64, @floatFromInt(screen.width_in_millimeters));
            const width_pixels = @as(f64, @floatFromInt(screen.width_in_pixels));
            if (width_mm > 0 and width_pixels > 0) { // Validate both dimensions
                const xres = (width_pixels * 25.4) / width_mm;
                if (xres > dpi and xres < 1000.0) { // Cap DPI to avoid outliers
                    dpi = xres;
                }
            } else {
                std.log.debug("Invalid screen metrics: width_mm={}, width_pixels={}", .{ width_mm, width_pixels });
            }
        }
        c.xcb_screen_next(&iter);
    }

    // Default DPI if all else fails
    if (dpi == 0) {
        dpi = 96.0;
        std.log.debug("Using default DPI: {}", .{dpi});
    }

    return dpi;
}
test "Fontconfig initialization and deinitialization" { //init main fontconfig
    const allocator = testing.allocator;
    var fc = try Fontconfig.init(allocator);
    defer fc.deinit();
}

test "Fontconfig queryFont" { // find config with str
    const allocator = testing.allocator;
    var fc = try Fontconfig.init(allocator);
    defer fc.deinit();

    const fontquery = "monospace:pixelsize=12";
    const pattern = try fc.queryFont(fontquery) orelse return error.NoFontFound;
    defer pattern.destroy();

    const family_val = pattern.get("family", 0) orelse return error.NoFamilyFound;
    // std.debug.print("family: {s}", .{family_val.string});
    try testing.expect(std.meta.activeTag(family_val) == .string);
    try testing.expect(family_val.string.len > 0);
}

test "Fontconfig queryByCharSupport" {
    const allocator = testing.allocator;
    var fc = try Fontconfig.init(allocator);
    defer fc.deinit();

    const dpi: f64 = 96;
    var ft = try fc.queryByCharSupport('A', null, dpi);
    defer ft.deinit();

    try testing.expect(ft.face != null);

    const glyph_index = ft.getCharIndex('A');
    try testing.expect(glyph_index != null);
}

test "FreeType initialization" {
    const allocator = testing.allocator;
    var ft = try FreeType.init(allocator);
    defer ft.deinit();

    try testing.expect(ft.library != null);
}

test "FreeType loadFaces" {
    const allocator = testing.allocator;
    var fc = try Fontconfig.init(allocator);
    defer fc.deinit();

    const fontquery = "monospace:pixelsize=12";
    const pattern = try fc.queryFont(fontquery) orelse return error.NoFontFound;
    defer pattern.destroy();

    const dpi: c_long = 96;
    var ft = try FreeType.loadFace(allocator, pattern, dpi);
    defer ft.deinit();

    try testing.expect(ft.face != null);
}

test "FreeType getCharIndex and loadGlyph" {
    const allocator = testing.allocator;
    var fc = try Fontconfig.init(allocator);
    defer fc.deinit();

    const fontquery = "monospace:pixelsize=12";
    const pattern = try fc.queryFont(fontquery) orelse return error.NoFontFound;
    defer pattern.destroy();

    const dpi: f64 = 96;
    var ft = try FreeType.loadFace(allocator, pattern, dpi);
    defer ft.deinit();

    const glyph_index = ft.getCharIndex('A') orelse return error.NoGlyphFound;
    try testing.expect(glyph_index > 0);

    try ft.loadGlyph(glyph_index, c.FT_LOAD_RENDER | c.FT_LOAD_FORCE_AUTOHINT);
    try ft.renderGlyph(c.FT_RENDER_MODE_NORMAL);

    const face = ft.face.?;
    const bitmap = face.*.glyph.*.bitmap;
    try testing.expect(bitmap.width > 0);
    try testing.expect(bitmap.rows > 0);
}

// test "XRenderFont initialization" {
//     const allocator = testing.allocator;
//     const conn = c.xcb_connect(null, null) orelse return error.XcbConnectionFailed;
//     defer c.xcb_disconnect(conn);

//     const fontquery = "monospace:pixelsize=12";
//     var font = try XRenderFont.init(conn, allocator, fontquery);
//     defer font.deinit();

//     try testing.expect(font.patterns.len > 0);
//     try testing.expect(font.patterns[0] != null);
//     try testing.expect(font.ft.faces.len > 0);
//     try testing.expect(font.ft.faces[0] != null);
//     try testing.expect(font.dpi > 0);
// }

// test "XRenderFont drawText preparation" {
//     const allocator = testing.allocator;
//     const conn = c.xcb_connect(null, null) orelse return error.XcbConnectionFailed;
//     defer c.xcb_disconnect(conn);

//     const fontquery = "monospace:pixelsize=12";
//     var font = try XRenderFont.init(conn, allocator, fontquery);
//     defer font.deinit();

//     var text = [_]u32{ 'H', 'e', 'l', 'l', 'o' };

//     const utf_holder = UtfHolder{ .str = @ptrCast(&text), .length = text.len };
//     const glyphset_advance = try font.loadGlyphset(utf_holder);
//     defer _ = c.xcb_render_free_glyph_set(conn, glyphset_advance.glyphset);

//     try testing.expect(glyphset_advance.advance.x > 0);
//     try testing.expect(glyphset_advance.advance.y == 0);
// }

// test "XRenderFont handle invalid codepoint" {
//     const allocator = testing.allocator;
//     const conn = c.xcb_connect(null, null) orelse return error.XcbConnectionFailed;
//     defer c.xcb_disconnect(conn);

//     const fontquery = "monospace:pixelsize=12";
//     var font = try XRenderFont.init(conn, allocator, fontquery);
//     defer font.deinit();

//     var text = [_]u32{ 'A', 0x110000 }; // Invalid codepoint
//     const utf_holder = UtfHolder{ .str = @ptrCast(&text), .length = text.len };

//     const glyphset_advance = try font.loadGlyphset(utf_holder);
//     defer _ = c.xcb_render_free_glyph_set(conn, glyphset_advance.glyphset);

//     try testing.expect(glyphset_advance.advance.x > 0); // Advance for 'A'
// }

// test "XRenderFont drawText" {
//     const allocator = testing.allocator;
//     const conn = c.xcb_connect(null, null) orelse return error.XcbConnectionFailed;
//     defer c.xcb_disconnect(conn);

//     const fontquery = "monospace:pixelsize=12";
//     var font = try XRenderFont.init(conn, allocator, fontquery);
//     defer font.deinit();

//     const text = [_]u32{ 'H', 'e', 'l', 'l', 'o' };
//     const color = c.xcb_render_color_t{
//         .red = 0xFFFF,
//         .green = 0xFFFF,
//         .blue = 0xFFFF,
//         .alpha = 0xFFFF,
//     };

//     const root = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn)).data.*.root;
//     const pmap = c.xcb_generate_id(conn);
//     _ = c.xcb_create_pixmap(conn, 32, pmap, root, 100, 100);
//     defer _ = c.xcb_free_pixmap(conn, pmap);

//     const advance = try font.drawText(pmap, 10, 20, &text, color);
//     try testing.expect(advance.x > 0);
//     try testing.expect(advance.y == 0);
// }
// test "getDpi fallback" { // failed
//     const conn = c.xcb_connect(null, null) orelse return error.XcbConnectionFailed;
//     defer c.xcb_disconnect(conn);

//     const dpi = try getDpi(conn);
//     try testing.expect(dpi >= 96);
// }
test "Pattern alignment" {
    const allocator = testing.allocator;
    var fc = try Fontconfig.init(allocator);
    defer fc.deinit();

    const fontquery = "monospace:pixelsize=12";
    const pattern = try fc.queryFont(fontquery) orelse return error.NoFontFound;
    defer pattern.destroy();

    const file_val = pattern.get("file", 0) orelse return error.NoFileFound;
    try testing.expect(std.meta.activeTag(file_val) == .string);
    try testing.expect(file_val.string.len > 0);
}
