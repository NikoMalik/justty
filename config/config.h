#ifndef CONFIG_H
#define CONFIG_H
#include <stdbool.h>
#include <stdint.h>



/*
 * appearance
 *
 * font: see http://freedesktop.org/software/fontconfig/fontconfig-user.html
 */
static const char font[] = "Liberation Mono:pixelsize=12";

static const uint16_t borderpx = 2;

static const char *colorname[] = {
    /* 8 normal colors (regular0–regular7) */
    "#000000",   /* 0: black       regular0 */
    "#ff5774",   /* 1: red         regular1 */
    "#6ae98a",   /* 2: green       regular2 */
    "#ffe099",   /* 3: yellow      regular3 */
    "#ff7a99",   /* 4: blue        regular4 */
    "#e0b2a5",   /* 5: magenta     regular5 */
    "#efdaa1",   /* 6: cyan        regular6 */
    "#bfbfbf",   /* 7: white       regular7 */

    /* 8 bright colors (bright0–bright7) */
    "#4d4d4d",   /* 8:  bright black   bright0 */
    "#ff6580",   /* 9:  bright red     bright1 */
    "#70f893",   /* 10: bright green   bright2 */
    "#ffe6ad",   /* 11: bright yellow  bright3 */
    "#ff8ba6",   /* 12: bright blue    bright4 */
    "#e8c4bb",   /* 13: bright magenta bright5 */
    "#ffe8ac",   /* 14: bright cyan    bright6 */
    "#e6e6e6",   /* 15: bright white   bright7 */

    [255] = 0,

    /* semantic colors (256–259) */
    "#ff7a99",   /* 256: cursor color        (blueish regular4) */
    "#efdaa1",   /* 257: reverse cursor/bg    (cyan regular6) */
    "#000000",   /* 258: background           (kitty background) */
    "#bfbfbf",   /* 259: foreground           (kitty foreground) */
};



/*
 * Default colors (colorname index)
 * foreground, background, cursor, reverse cursor
 */
static const unsigned int defaultbg = 258;
static const unsigned int defaultfg = 259;
static const unsigned int defaultcs = 256;
static const unsigned int defaultrcs = 257;

static const bool scroll_bool = true;



/*
 * Default shape of cursor
 * 152: Text ("█")
 * 58:  Hand
 * 132: Arrow
 * 68: default
 */

static const uint16_t CURSORSHAPE = 152;



/*
 * Default colour and shape of the mouse cursor
 */
// static unsigned int mouseshape = XC_xterm;
static const unsigned int mousefg = 7;
static const unsigned int mousebg = 0;




static const unsigned char cols = 80;
static const unsigned char rows = 24;//start rows when started app,can be dynamicly resized







/*
 * Maximum rows and columns
 *
 * To calculate MAX_ROWS and MAX_COLS, use the following formulas based on the window size and font:
 *
 * MAX_ROWS = floor((window_height - 2 * borderpx) / char_height)
 * MAX_COLS = floor((window_width - 2 * borderpx) / char_width)

  How to find char_height and char_width:
 * Simplest way to find char_height and char_width:
 * - Check the font setting in this file (e.g., "Liberation Mono:pixelsize=12").
 * - For monospaced fonts like Liberation Mono, use approximate values based on pixelsize:
 *   - char_height ≈ pixelsize * 1.3 (includes line spacing)
 *   - char_width ≈ char_height * 0.5
 *   - Example for pixelsize=12:
 *     - char_height ≈ 12 * 1.3 ≈ 16 pixels
 *     - char_width ≈ 16 * 0.5 ≈ 8 pixels
 * - Alternatively, use this table for typical monospaced fonts:
 *   | Pixelsize | char_width (pixels) | char_height (pixels) |
 *   |-----------|---------------------|----------------------|
 *   | 10        | ~6–7                | ~12–14              |
 *   | 12        | ~7–8                | ~14–16              |
 *   | 14        | ~8–9                | ~16–18              |
 *   | 16        | ~9–10               | ~18–20              |
 * - For this terminal (pixelsize=12), use: char_width = 8, char_height = 16.
 * 1. Using terminal output:
 *    - Open the terminal and run:
 *      ```bash
 *      echo $LINES $COLUMNS
 *      ```
 *    - Measure the window size in pixels (e.g., using `xwininfo` or window manager settings).
 *    - Calculate:
 *      - char_width = (window_width - 4) / $COLUMNS
 *      - char_height = (window_height - 4) / $LINES
 *    - Example for Full HD (1920x1080, $COLUMNS=240, $LINES=67):
 *      - char_width = (1920 - 4) / 240 ≈ 8 pixels
 *      - char_height = (1080 - 4) / 67 ≈ 16 pixels
 * 2. Using fontconfig:
 *    - Run:
 *      ```bash
 *      fc-match -v "Liberation Mono:pixelsize=12" | grep -E "size|spacing"
 *      ```
 *    - Check `size` for approximate height (~12–16 pixels) and confirm monospaced font (spacing=100).
 *    - Width is typically 70% of height (~8 pixels for pixelsize=12).
 * 3. Measure manually:
 *    - Take a screenshot of the terminal with text.
 *    - Use an image editor (e.g., GIMP) to measure the width and height of a single character.
 * 4. Check terminal code:
 *    - If you have access to the source code, check the `Font.size` structure for `width` and `height`.
 *
 *
 * Where:
 * - window_height: Height of the window or screen in pixels (e.g., 1080 for Full HD).
 * - window_width: Width of the window or screen in pixels (e.g., 1920 for Full HD).
 * - borderpx: Border padding (2 pixels per side, so 4 pixels total).
 * - char_height: Height of a character in pixels (e.g., ~16 pixels for Liberation Mono:pixelsize=12).
 * - char_width: Width of a character in pixels (e.g., ~8 pixels for Liberation Mono:pixelsize=12).
 * - floor(x): Round down to the nearest integer.
 *
 * Example for Full HD (1920x1080):
 * - Effective width: 1920 - 4 = 1916 pixels
 * - Effective height: 1080 - 4 = 1076 pixels
 * - Columns: floor(1916 / 8) = 239
 * - Rows: floor(1076 / 16) = 67
 *
 * For 4K (3840x2160):
 * - Effective width: 3840 - 4 = 3836 pixels
 * - Effective height: 2160 - 4 = 2156 pixels
 * - Columns: floor(3836 / 8) = 479
 * - Rows: floor(2156 / 16) = 134
 *
 * Current settings:
 * - MAX_ROWS = 67: Suitable for Full HD (~67 rows) but limits 1440p (~89 rows) and 4K (~134 rows).
 * - MAX_COLS = 240: Suitable for Full HD (~239 columns) but limits 1440p (~319 columns) and 4K (~479 columns).
 *
 * Recommendation: Set MAX_ROWS = 256 and MAX_COLS = 512 to support up to 4K and ultrawide monitors.
 */
#define MAX_ROWS 67
#define MAX_COLS 240

/*
 * Typical values for different resolutions (assuming char_width = 8, char_height = 16):
 * Resolution         | Width (px) | Max columns | Height (px) | Max rows
 * 1366x768 (768p)    | 1366       | ~170        | 768         | ~47
 * 1920x1080 (1080p)  | 1920       | ~239        | 1080        | ~67
 * 2560x1440 (1440p)  | 2560       | ~319        | 1440        | ~89
 * 3440x1440 (UWQHD)  | 3440       | ~429        | 1440        | ~89
 * 3840x2160 (4K UHD) | 3840       | ~479        | 2160        | ~134
 */




#endif
