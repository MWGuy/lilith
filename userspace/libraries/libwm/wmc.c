#include "wm.h"
#define LIBWM_IMPLEMENTATION
#include "wmc.h"

int wmc_connection_init(struct wmc_connection *conn) {
  conn->wm_control_fd = open("/pipes/wm", O_WRONLY);
  if(conn->wm_control_fd < 0) {
    return 0;
  }
  conn->win_fd_m = -1;
  conn->win_fd_s = -1;
  return 1;
}

void wmc_connection_deinit(struct wmc_connection *conn) {
  close(conn->wm_control_fd);
  if(conn->win_fd_m > 0)
    close(conn->win_fd_m);
  if(conn->win_fd_m > 0)
    close(conn->win_fd_s);
    
  char path[128] = { 0 };
  pid_t pid = getpid();

  snprintf(path, sizeof(path), "/pipes/wm:%d:m", pid);
  remove(path);

  snprintf(path, sizeof(path), "/pipes/wm:%d:s", pid);
  remove(path);
}

void wmc_connection_obtain(struct wmc_connection *conn, unsigned int event_mask, unsigned int properties) {
    struct wm_connection_request conn_req = {
      .pid = getpid(),
      .event_mask = event_mask,
      .properties = properties,
    };
    write(conn->wm_control_fd, (char *)&conn_req, sizeof(struct wm_connection_request));
    while(1) {
      // try to poll for pipes
      char path[128] = { 0 };

      if(conn->win_fd_m == -1) {
	snprintf(path, sizeof(path), "/pipes/wm:%d:m", conn_req.pid);
	if((conn->win_fd_m = open(path, O_RDONLY)) < 0) {
	  goto await_conn;
	}
      }

      if(conn->win_fd_s == -1) {
	snprintf(path, sizeof(path), "/pipes/wm:%d:s", conn_req.pid);
	if((conn->win_fd_s = open(path, O_WRONLY)) < 0) {
	  goto await_conn;
	}
      }

      if(conn->win_fd_m != -1 && conn->win_fd_s != -1) {
	break;
      }

    await_conn:
        usleep(1);
    }
}

int wmc_send_atom(struct wmc_connection *conn, struct wm_atom *atom) {
  return write(conn->win_fd_s, (char *)atom, sizeof(struct wm_atom));
}

int wmc_recv_atom(struct wmc_connection *conn, struct wm_atom *atom) {
  if(atom == NULL) {
    struct wm_atom unused;
    return read(conn->win_fd_m, (char *)&unused, sizeof(struct wm_atom));
  }
  return read(conn->win_fd_m, (char *)atom, sizeof(struct wm_atom));
}

int wmc_wait_atom(struct wmc_connection *conn, useconds_t timeout) {
  return waitfd(&conn->win_fd_m, 1, timeout);
}

int wmc_open_bitmap(struct wmc_connection *conn) {
  char path[128];
  snprintf(path, sizeof(path), "/tmp/wm:%d:bm", getpid());
  return open(path, O_RDWR);
}
