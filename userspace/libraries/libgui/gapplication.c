#include <string.h>
#include <wm/wmc.h>
#include <canvas.h>
#include <sys/gfx.h>
#include <sys/ioctl.h>
#include "gui.h"
#include "priv/coords.h"
#include "priv/gapplication-impl.h"
#include "priv/gwidget-impl.h"

// application
struct g_application *g_application_create(int width, int height, int alpha) {
  struct g_application *app = malloc(sizeof(struct g_application));
  if(!app) {
    return 0;
  }
  app->bitmapfd = -1;
	if(!wmc_connection_init(&app->wmc_conn)) {
    free(app);
    return 0;
  }
  app->sprite = (struct g_application_sprite){
    .source = 0,
    .x = 0,
    .y = 0,
    .width  = width,
    .height = height,
    .alpha = alpha,
  };
  app->ctx = canvas_ctx_create(app->sprite.width,
                 app->sprite.height,
                 alpha ? LIBCANVAS_FORMAT_ARGB32 : LIBCANVAS_FORMAT_RGB24);
  app->sprite.source = (unsigned int *)canvas_ctx_get_surface(app->ctx);
  g_widget_array_init(&app->widgets);
  app->event_mask = ATOM_MOUSE_EVENT_MASK | ATOM_KEYBOARD_EVENT_MASK;

  if(!app->ctx) {
    // close(app->fb_fd);
    wmc_connection_deinit(&app->wmc_conn);
    free(app);
    return 0;
  }
  app->redraw_cb = 0;
  app->key_cb = 0;
  app->mouse_cb = 0;
  app->timeout_cb = 0;
  app->usec_timeout = (useconds_t)-1;
  app->userdata = 0;
  return app;
}

void g_application_set_window_properties(struct g_application *app, unsigned int properties) {
  app->wm_properties = properties;
}

void g_application_destroy(struct g_application *app) {
  munmap(app->bitmap);
  close(app->bitmapfd);
  
  struct wm_atom close_atom = {
    .type = ATOM_WIN_CLOSE_TYPE
  };
  int retries = 0;
  const int max_retries = 5;
  struct wm_atom atom;
  while (wmc_recv_atom(&app->wmc_conn, &atom) >= 0 && retries < max_retries) {
    wmc_send_atom(&app->wmc_conn, &close_atom);
    wmc_wait_atom(&app->wmc_conn, (useconds_t)-1);
    retries++;
  }
  wmc_connection_deinit(&app->wmc_conn);
  free(app);
}

void g_application_close(struct g_application *app) {
  app->running = 0;
}

int g_application_redraw(struct g_application *app) {
  int needs_redraw = 0;
  if (app->redraw_cb) {
    if (app->redraw_cb(app))
      needs_redraw = 1;
  }
  if(app->main_widget) {
    if(app->main_widget->redraw_fn(app->main_widget))
      needs_redraw = 1;
  } else {
    for(size_t i = 0; i < app->widgets.len; i++) {
      struct g_widget *widget = app->widgets.data[i];
      if(widget->redraw_fn(widget)) {
        canvas_ctx_bitblit(app->ctx, widget->ctx, widget->x, widget->y);
        needs_redraw = 1;
      }
    }
  }
  return needs_redraw;
}

static void g_application_on_key(struct g_application *app, int ch) {
  if (app->key_cb) {
    app->key_cb(app, ch);
  }
  if(app->main_widget) {
    app->main_widget->on_key_fn(app->main_widget, ch);
  } else {
    for(size_t i = 0; i < app->widgets.len; i++) {
      struct g_widget *widget = app->widgets.data[i];
      if(widget->on_key_fn) {
        widget->on_key_fn(widget, ch);
      }
    }
  }
}

static int g_application_on_mouse(struct g_application *app, int type,
                                  unsigned int x, unsigned int y,
                                  int delta_x, int delta_y) {
  unsigned int tx = x - app->sprite.x;
  unsigned int ty = y - app->sprite.y;
  int retval = 0;
  if (app->mouse_cb) {
    if (app->mouse_cb(app, tx, ty, delta_x, delta_y))
      retval = 1;
  }
  if(app->main_widget) {
    if(app->main_widget->on_mouse_fn(app->main_widget, type,
        tx, ty, delta_x, delta_y))
      retval = 1;
  } else {
    for(size_t i = 0; i < app->widgets.len; i++) {
      struct g_widget *widget = app->widgets.data[i];
      if(widget->on_mouse_fn) {
        if(widget->on_mouse_fn(widget, type, tx, ty, delta_x, delta_y))
          retval = 1;
      }
    }
  }
  return retval;
}

int g_application_run(struct g_application *app) {
  wmc_connection_obtain(&app->wmc_conn, app->event_mask, app->wm_properties);

  // obtain a window
  {
    struct wm_atom obtain_atom = {
      .type = ATOM_WIN_CREATE_TYPE,
      .win_create = (struct wm_atom_win_create) {
        .width = app->sprite.width,
        .height = app->sprite.height,
        .alpha = app->sprite.alpha,
      }
    };
    int retries = 0;
    const int max_retries = 3;
    while (retries < max_retries) {
      struct wm_atom atom;
      wmc_send_atom(&app->wmc_conn, &obtain_atom);
      wmc_wait_atom(&app->wmc_conn, app->usec_timeout);
      if(wmc_recv_atom(&app->wmc_conn, &atom) == sizeof(struct wm_atom)) {
        if(atom.type == ATOM_RESPOND_TYPE && atom.respond.retval == 1) {
          struct wm_atom respond_atom = {
            .type = ATOM_RESPOND_TYPE,
            .respond.retval = 1,
          };
          wmc_send_atom(&app->wmc_conn, &respond_atom);
        } else {
          printf("unable to obtain window\n");
          retries++;
          continue;
        }
      } else {
        printf("unable to receive packet\n");
        retries++;
        continue;
      }
      app->bitmapfd = wmc_open_bitmap(&app->wmc_conn);
      app->bitmap = mmap(app->bitmapfd, (size_t)-1);
      if(app->bitmap >= 0) {
        break;
      }
    }
    if(app->bitmap < 0) {
      printf("unable to obtain window after %d attempts\n", retries);
      return -1;
    }
  }

  // event loop
  int mouse_drag = 0;
  int mouse_resize = 0;
  app->running = 1;

  struct wm_atom atom;
  int needs_redraw = 0;
  int retval = 0;
  while ((retval = wmc_recv_atom(&app->wmc_conn, &atom)) >= 0 && app->running) {
    if(retval == 0)
      goto wait;
    switch (atom.type) {
      case ATOM_REDRAW_TYPE: {
        struct wm_atom respond_atom = {
          .type = ATOM_WIN_REFRESH_TYPE,
          .win_refresh.did_redraw = 0,
        };
        needs_redraw = g_application_redraw(app);
        if (needs_redraw) {
          needs_redraw = 0;
          respond_atom.win_refresh.did_redraw = 1;
          size_t sz = app->sprite.width * app->sprite.height * 4;
          memcpy(app->bitmap, app->sprite.source, sz);
        }
        wmc_send_atom(&app->wmc_conn, &respond_atom);
        break;
      }
      case ATOM_MOVE_TYPE: {
        app->sprite.x = atom.move.x;
        app->sprite.y = atom.move.y;
        needs_redraw = 1;

        struct wm_atom respond_atom = {
          .type = ATOM_RESPOND_TYPE,
          .respond.retval = 0,
        };
        wmc_send_atom(&app->wmc_conn, &respond_atom);
        break;
      }
      case ATOM_MOUSE_EVENT_TYPE: {
        if(atom.mouse_event.type == WM_MOUSE_PRESS &&
           (is_coord_in_sprite(&app->sprite,
                     atom.mouse_event.x,
                     atom.mouse_event.y) ||
          mouse_drag)) {

          if((app->wm_properties & WM_PROPERTY_ROOT) != 0) {
            mouse_drag = 0;
            mouse_resize = 0;
            goto wait;
          }
            
          if(g_application_on_mouse(app, atom.mouse_event.type,
                                 atom.mouse_event.x,
                                 atom.mouse_event.y,
                                 atom.mouse_event.delta_x,
                                 atom.mouse_event.delta_y)) {
            struct wm_atom respond_atom = {
              .type = ATOM_RESPOND_TYPE,
              .respond.retval = 0,
            };
            wmc_send_atom(&app->wmc_conn, &respond_atom);
            goto wait;
          }

          mouse_drag = 1;
          if(is_coord_in_bottom_right_corner(&app->sprite,
            atom.mouse_event.x,
            atom.mouse_event.y) || mouse_resize) {
            // resize
            mouse_resize = 1;
            g_application_resize(app,
                            app->sprite.width + atom.mouse_event.delta_x,
                            app->sprite.height + atom.mouse_event.delta_y);
          } else {
            int changed = 0;
            if(!(atom.mouse_event.delta_x < 0 && app->sprite.x < -atom.mouse_event.delta_x)) {
              app->sprite.x += atom.mouse_event.delta_x;
              changed = 1;
            }
            if(!(atom.mouse_event.delta_y < 0 && app->sprite.y < -atom.mouse_event.delta_y)) {
              app->sprite.y += atom.mouse_event.delta_y;
              changed = 1;
            }
            if(changed) {
              struct wm_atom respond_atom = {
                .type = ATOM_MOVE_TYPE,
                .move = (struct wm_atom_move) {
                  .x = app->sprite.x,
                  .y = app->sprite.y,
                }
              };
              wmc_send_atom(&app->wmc_conn, &respond_atom);
            }
          }
        } else if (atom.mouse_event.type == WM_MOUSE_RELEASE && mouse_drag) {
          mouse_drag = 0;
          mouse_resize = 0;
        }

        needs_redraw = 1;

        struct wm_atom respond_atom = {
          .type = ATOM_RESPOND_TYPE,
          .respond.retval = 0,
        };
        wmc_send_atom(&app->wmc_conn, &respond_atom);
        break;
      }
      case ATOM_KEYBOARD_EVENT_TYPE: {
        g_application_on_key(app, atom.keyboard_event.ch);

        struct wm_atom respond_atom = {
          .type = ATOM_RESPOND_TYPE,
          .respond.retval = 0,
        };
        wmc_send_atom(&app->wmc_conn, &respond_atom);
        break;
      }
    }
  wait:
    if(app->timeout_cb)
      app->timeout_cb(app);
    wmc_wait_atom(&app->wmc_conn, app->usec_timeout);
  }
  
  g_application_destroy(app);
  
  if(app->close_cb)
    return app->close_cb(app);
  return 0;
}

void g_application_set_main_widget(struct g_application *app, struct g_widget *widget) {
  app->main_widget = widget;
  app->main_widget->app = app;
}

struct g_widget *g_application_main_widget(struct g_application *app) {
  return app->main_widget;
}

unsigned int g_application_event_mask(struct g_application *app) {
  return app->event_mask;
}

void g_application_add_widget(struct g_application *app, struct g_widget *widget) {
  g_widget_array_push(g_application_widgets(app), widget);
  widget->app = app;
}

// getters

struct g_widget_array *g_application_widgets(struct g_application *app) {
  return &app->widgets;
}

struct canvas_ctx *g_application_ctx(struct g_application *app) {
  return app->ctx;
}

int g_application_x(struct g_application *app) {
  return app->sprite.x;
}

int g_application_y(struct g_application *app) {
  return app->sprite.y;
}

int g_application_width(struct g_application *app) {
  return app->sprite.width;
}

int g_application_height(struct g_application *app) {
  return app->sprite.height;
}

void g_application_resize(struct g_application *app, int width, int height) {
  munmap(app->bitmap);

  struct wm_atom resize_atom = {
    .type = ATOM_RESIZE_TYPE,
    .resize = (struct wm_atom_resize){
      .width = width,
      .height = height,
    },
  };
  int retries = 0;
  const int max_retries = 5;
  while (retries < max_retries) {
    wmc_send_atom(&app->wmc_conn, &resize_atom);
    wmc_wait_atom(&app->wmc_conn, (useconds_t)-1);
    
    size_t expected_size = width * height * 4;
    size_t seek_size = lseek(app->bitmapfd, 0, SEEK_END);
    if(seek_size == expected_size) {
      app->bitmap = mmap(app->bitmapfd, (size_t)-1);
      canvas_ctx_resize_buffer(app->ctx, width, height);
      app->sprite.source = (unsigned int *)canvas_ctx_get_surface(app->ctx);
      app->sprite.width = width;
      app->sprite.height = height;
      if(app->main_widget) {
        g_widget_move_resize(app->main_widget, 0, 0, width, height);
      }
      return;
    }
    retries++;
  }
  app->bitmap = mmap(app->bitmapfd, (size_t)-1);
}

void g_application_set_event_mask(struct g_application *app, unsigned int event_mask) {
  app->event_mask = event_mask;
}

// screen

int g_application_screen_size(struct g_application *app, int *width, int *height) {
  // FIXME: expose display information through window manager
  struct winsize ws;
  int fb_fd = open("/fb0", O_RDWR);
  int retval = ioctl(fb_fd, TIOCGWINSZ, &ws);
  if(retval == 0) {
    if(width)
      *width = (int)ws.ws_col;
    if(height)
      *height = (int)ws.ws_row;
  }
  close(fb_fd);
  return retval;
}

// properties

void *g_application_userdata(struct g_application *app) {
  return app->userdata;
}

void g_application_set_userdata(struct g_application *app, void *ptr) {
  app->userdata = ptr;
}

// callbacks

void g_application_set_redraw_cb(struct g_application *app, g_redraw_cb cb) {
  app->redraw_cb = cb;
}

void g_application_set_key_cb(struct g_application *app, g_key_cb cb) {
  app->key_cb = cb;
}

void g_application_set_mouse_cb(struct g_application *app, g_mouse_cb cb) {
  app->mouse_cb = cb;
}

void g_application_set_close_cb(struct g_application *app, g_close_cb cb) {
  app->close_cb = cb;
}

void g_application_set_timeout_cb(struct g_application *app, useconds_t usec, g_timeout_cb cb) {
  app->usec_timeout = usec;
  app->timeout_cb = cb;
}
