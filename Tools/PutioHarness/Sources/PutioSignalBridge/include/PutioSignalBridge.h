#ifndef PUTIO_SIGNAL_BRIDGE_H
#define PUTIO_SIGNAL_BRIDGE_H

#include <stdint.h>

enum PutioTerminationEventKind {
  PUTIO_TERMINATION_SIGNAL = 1,
  PUTIO_TERMINATION_COMPLETION = 2,
};

int32_t putio_termination_bridge_install(void);
int32_t putio_termination_bridge_request_completion(int32_t status);
int32_t putio_termination_bridge_read(int32_t descriptor, int32_t *kind, int32_t *value);
int32_t putio_termination_bridge_ignore_signals(void);

#endif
