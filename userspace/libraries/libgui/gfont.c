#include "gui.h"
#include <font8x8_basic.h>

void canvas_ctx_draw_character(struct canvas_ctx *ctx, int xs, int ys, const char ch) {
  char *bitmap = font8x8_basic[(int)ch];
  switch(canvas_ctx_get_format(ctx)) {
    case LIBCANVAS_FORMAT_ARGB32:
      // fallthrough
    case LIBCANVAS_FORMAT_RGB24: {
      unsigned long *data = (unsigned long *)canvas_ctx_get_surface(ctx);
      int cwidth = canvas_ctx_get_width(ctx);
      int cheight = canvas_ctx_get_height(ctx);
      if(xs < 0 || xs + FONT_WIDTH > cwidth)
        return;
      if(ys < 0 || ys + FONT_HEIGHT > cheight)
        return;
      for (int x = 0; x < FONT_WIDTH; x++) {
        for (int y = 0; y < FONT_HEIGHT; y++) {
          if (bitmap[y] & 1 << x) {
            data[(ys + y) * cwidth + (xs + x)] = 0xffffffff;
          }
        }
      }
      break;
    }
  }
}

void canvas_ctx_draw_text(struct canvas_ctx *ctx, int xs, int ys, const char *s) {
  int x = xs;
  while(*s) {
    canvas_ctx_draw_character(ctx, x, ys, *s);
    x += FONT_WIDTH;
    s++;
  }
}
