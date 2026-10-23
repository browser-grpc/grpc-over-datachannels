/* Stdio transport for the C interop harness: frames DataChannel
   messages over a byte stream with a 4-byte big-endian length
   prefix (the prefix exists only to frame messages on a byte
   stream; each framed unit is exactly one DataChannel message). */
#ifndef GRPCDC_STDIO_TRANSPORT_H
#define GRPCDC_STDIO_TRANSPORT_H

#include "grpcdc/grpcdc.h"

typedef struct {
    int in_fd;
    int out_fd;
    uint8_t *pending;
    size_t pending_len;
    size_t pending_cap;
    int eof;
} stdio_transport;

void stdio_transport_init(stdio_transport *t, int in_fd, int out_fd);
grpcdc_transport stdio_transport_iface(stdio_transport *t);

#endif /* GRPCDC_STDIO_TRANSPORT_H */
