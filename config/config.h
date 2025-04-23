#ifndef CONFIG_H
#define CONFIG_H
#include <stdbool.h>
#include <stdint.h>



/*
 * appearance
 *
 * font: see http://freedesktop.org/software/fontconfig/fontconfig-user.html
 */
static const char *font = "Liberation Mono:pixelsize=12";

static const uint16_t borderpx = 2;

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
static unsigned int defaultbg = 258;
static unsigned int defaultfg = 259;
static unsigned int defaultcs = 256;
static unsigned int defaultrcs = 257;

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
static const unsigned char rows = 24;




#endif
