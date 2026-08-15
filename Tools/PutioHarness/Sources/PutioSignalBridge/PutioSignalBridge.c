#include "PutioSignalBridge.h"

#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

struct PutioTerminationEvent {
  int32_t kind;
  int32_t value;
};

static int putio_termination_pipe[2] = {-1, -1};
static _Atomic int putio_terminal_claimed;

static int putio_claim_terminal_event(void) {
  int expected = 0;
  return atomic_compare_exchange_strong_explicit(
      &putio_terminal_claimed,
      &expected,
      1,
      memory_order_relaxed,
      memory_order_relaxed);
}

static int putio_write_terminal_event(const struct PutioTerminationEvent *event) {
  ssize_t count;
  do {
    count = write(putio_termination_pipe[1], event, sizeof(*event));
  } while (count < 0 && errno == EINTR);
  return count == sizeof(*event) ? 0 : -1;
}

static void putio_record_termination_signal(int signal_number) {
  if (!putio_claim_terminal_event()) {
    return;
  }
  struct PutioTerminationEvent event = {
      .kind = PUTIO_TERMINATION_SIGNAL,
      .value = signal_number,
  };
  if (putio_write_terminal_event(&event) != 0) {
    atomic_store_explicit(&putio_terminal_claimed, 0, memory_order_relaxed);
  }
}

int32_t putio_termination_bridge_install(void) {
  atomic_init(&putio_terminal_claimed, 0);
  if (!atomic_is_lock_free(&putio_terminal_claimed)) {
    return -1;
  }
  if (pipe(putio_termination_pipe) != 0) {
    return -1;
  }

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = putio_record_termination_signal;
  sigemptyset(&action.sa_mask);
  sigaddset(&action.sa_mask, SIGINT);
  sigaddset(&action.sa_mask, SIGTERM);
  if (sigaction(SIGINT, &action, NULL) != 0 || sigaction(SIGTERM, &action, NULL) != 0) {
    close(putio_termination_pipe[0]);
    close(putio_termination_pipe[1]);
    putio_termination_pipe[0] = -1;
    putio_termination_pipe[1] = -1;
    return -1;
  }
  return putio_termination_pipe[0];
}

int32_t putio_termination_bridge_request_completion(int32_t status) {
  if (!putio_claim_terminal_event()) {
    return 0;
  }
  struct PutioTerminationEvent event = {
      .kind = PUTIO_TERMINATION_COMPLETION,
      .value = status,
  };
  if (putio_write_terminal_event(&event) == 0) {
    return 0;
  }
  atomic_store_explicit(&putio_terminal_claimed, 0, memory_order_relaxed);
  return -1;
}

int32_t putio_termination_bridge_read(
    int32_t descriptor,
    int32_t *kind,
    int32_t *value) {
  struct PutioTerminationEvent event;
  ssize_t count;
  do {
    count = read(descriptor, &event, sizeof(event));
  } while (count < 0 && errno == EINTR);
  if (count != sizeof(event)) {
    return -1;
  }
  *kind = event.kind;
  *value = event.value;
  return 0;
}

int32_t putio_termination_bridge_ignore_signals(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_IGN;
  sigemptyset(&action.sa_mask);
  return sigaction(SIGINT, &action, NULL) == 0 && sigaction(SIGTERM, &action, NULL) == 0 ? 0 : -1;
}
