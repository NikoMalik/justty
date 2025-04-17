#ifndef CONFIG_H
#define CONFIG_H
#include <stdbool.h>
#include <stdint.h>



/*
 * appearance
 *
 * font: see http://freedesktop.org/software/fontconfig/fontconfig-user.html
 */
static char *font = "Liberation Mono:pixelsize=12";

static uint32_t borderpx = 2;

// /* Terminal colors (16 first used in escape sequence) */
// static const char *colorname[] = {
// 	/* 8 normal colors */
// 	"black",
// 	"red3",
// 	"green3",
// 	"yellow3",
// 	"blue2",
// 	"magenta3",
// 	"cyan3",
// 	"gray90",

// 	/* 8 bright colors */
// 	"gray50",
// 	"red",
// 	"green",
// 	"yellow",
// 	"#5c5cff",
// 	"magenta",
// 	"cyan",
// 	"white",

// 	[255] = 0,

// 	/* more colors can be added after 255 to use with DefaultXX */
// 	"#cccccc",
// 	"#555555",
// 	"gray90", /* default foreground colour */
// 	"black", /* default background colour */
// };


//gruber-darker
//
static const char *colorname[] = {
    /* 8 normal colors */
    "#181818", /* black */
    "#F43841", /* red */
    "#73D936", /* green */
    "#FFDD33", /* yellow */
    "#96A6C8", /* blue */
    "#9E95C7", /* magenta */
    "#95A99F", /* cyan */
    "#E4E4E4", /* white */

    /* 8 bright colors */
    "#52494E", /* bright black */
    "#FF4F58", /* bright red */
    "#73D936", /* bright green */
    "#FFDD33", /* bright yellow */
    "#96A6C8", /* bright blue */
    "#AFAFD7", /* bright magenta */
    "#95A99F", /* bright cyan */
    "#F5F5F5", /* bright white */

    [16] = "#222222", /* indexed color 16 */

    [255] = 0,

    /* special colors */
    "#E4E4E4",
    "#181818", /* 257 -> reverse cursor (background) */
    "#181818", /* 258 -> background */
    "#e4e4ef", /* 259 -> foreground */
};




/*
 * Default colors (colorname index)
 * foreground, background, cursor, reverse cursor
 */
unsigned int defaultfg = 258;
unsigned int defaultbg = 259;
unsigned int defaultcs = 256;
static unsigned int defaultrcs = 257;

static bool scroll_bool = true;



/*
 * Default shape of cursor
 * 2: Block ("█")
 */

static unsigned int cursorshape = 2;



/*
 * Default colour and shape of the mouse cursor
 */
static unsigned int mouseshape = XC_xterm;
static unsigned int mousefg = 7;
static unsigned int mousebg = 0;




static unsigned char cols = 80;
static unsigned char rows = 24;




#endif
