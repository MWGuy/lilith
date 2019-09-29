#include <wm/wmc.h>
#include <canvas.h>
#include <stdlib.h>
#include <string.h>

#include "gui.h"
#include "priv/gwidget-impl.h"

static int g_canvas_redraw_stub(struct g_widget *widget) {
  return 0;
}

struct g_canvas *g_canvas_create(struct g_application *app) {
  struct g_widget *canvas = calloc(1, sizeof(struct g_widget));
  canvas->app = app;
  canvas->needs_redraw = 1;
  canvas->redraw_fn = g_canvas_redraw_stub;
  return (struct g_canvas *)canvas;
}

// getters
struct canvas_ctx *g_canvas_ctx(struct g_canvas *canvas) {
  g_widget_init_ctx((struct g_widget *)canvas);
  return ((struct g_widget *)canvas)->ctx;
}

void *g_canvas_userdata(struct g_canvas *canvas) {
  return ((struct g_widget *)canvas)->widget_data;
}

// setters
void g_canvas_set_userdata(struct g_canvas *canvas, void *userdata) {
  ((struct g_widget *)canvas)->widget_data = userdata;
}

void g_canvas_set_redraw_fn(struct g_canvas *canvas, g_canvas_redraw_fn fn) {
  ((struct g_widget *)canvas)->redraw_fn = fn;
}

void g_canvas_set_on_mouse_fn(struct g_canvas *canvas, g_canvas_on_mouse_fn fn) {
 ((struct g_widget *)canvas)->on_mouse_fn = fn;
}
