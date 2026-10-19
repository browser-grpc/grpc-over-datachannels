#include "stdio_transport.h"

#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

static int write_all(int fd, const uint8_t *data, size_t len) {
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n <= 0) return -1;
        written += (size_t)n;
    }
    return 0;
}

static int stdio_send(void *ctx, const uint8_t *data, size_t len) {
    stdio_transport *t = (stdio_transport *)ctx;
    uint8_t header[4] = {(uint8_t)((len >> 24) & 0xff),
                         (uint8_t)((len >> 16) & 0xff),
                         (uint8_t)((len >> 8) & 0xff),
                         (uint8_t)(len & 0xff)};
    if (write_all(t->out_fd, header, 4) != 0) return -1;
    return write_all(t->out_fd, data, len);
}

static int stdio_recv(void *ctx, uint8_t **out, size_t *len) {
    stdio_transport *t = (stdio_transport *)ctx;
    for (;;) {
        if (t->pending_len >= 4) {
            uint32_t n = ((uint32_t)t->pending[0] << 24) |
                         ((uint32_t)t->pending[1] << 16) |
                         ((uint32_t)t->pending[2] << 8) |
                         (uint32_t)t->pending[3];
            if (t->pending_len >= 4 + (size_t)n) {
                uint8_t *msg = (uint8_t *)malloc(n ? n : 1);
                if (n) memcpy(msg, t->pending + 4, n);
                size_t rest = t->pending_len - (4 + (size_t)n);
                if (rest)
                    memmove(t->pending, t->pending + 4 + n, rest);
                t->pending_len = rest;
                *out = msg;
                *len = n;
                return 0;
            }
        }
        if (t->eof) return -1;
        uint8_t buf[16384];
        ssize_t got = read(t->in_fd, buf, sizeof(buf));
        if (got < 0) return -1;
        if (got == 0) {
            t->eof = 1;
            return -1;
        }
        if (t->pending_len + (size_t)got > t->pending_cap) {
            size_t cap = t->pending_cap ? t->pending_cap * 2 : 16384;
            while (cap < t->pending_len + (size_t)got) cap *= 2;
            t->pending = (uint8_t *)realloc(t->pending, cap);
            t->pending_cap = cap;
        }
        memcpy(t->pending + t->pending_len, buf, (size_t)got);
        t->pending_len += (size_t)got;
    }
}

static int64_t stdio_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Timed variant: the byte pump reads with poll so a deadline can
   fire mid-wait. Returns -2 on timeout. */
static int stdio_recv_until(void *ctx, uint8_t **out, size_t *len,
                            int64_t abs_deadline_ms) {
    stdio_transport *t = (stdio_transport *)ctx;
    for (;;) {
        /* First try to complete a frame from buffered bytes by
           peeking through the blocking path state: emulate by
           checking pending length. */
        if (t->pending_len >= 4) {
            uint32_t n = ((uint32_t)t->pending[0] << 24) |
                         ((uint32_t)t->pending[1] << 16) |
                         ((uint32_t)t->pending[2] << 8) |
                         (uint32_t)t->pending[3];
            if (t->pending_len >= 4 + (size_t)n)
                return stdio_recv(ctx, out, len);
        }
        if (t->eof) return -1;
        int64_t remaining = abs_deadline_ms - stdio_now_ms();
        if (remaining < 0) remaining = 0;
        struct pollfd pfd;
        pfd.fd = t->in_fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, (int)remaining);
        if (rc == 0) return -2;
        if (rc < 0) return -1;
        uint8_t buf[16384];
        ssize_t got = read(t->in_fd, buf, sizeof(buf));
        if (got < 0) return -1;
        if (got == 0) {
            t->eof = 1;
            return -1;
        }
        if (t->pending_len + (size_t)got > t->pending_cap) {
            size_t cap = t->pending_cap ? t->pending_cap * 2 : 16384;
            while (cap < t->pending_len + (size_t)got) cap *= 2;
            t->pending = (uint8_t *)realloc(t->pending, cap);
            t->pending_cap = cap;
        }
        memcpy(t->pending + t->pending_len, buf, (size_t)got);
        t->pending_len += (size_t)got;
    }
}

void stdio_transport_init(stdio_transport *t, int in_fd, int out_fd) {
    memset(t, 0, sizeof(*t));
    t->in_fd = in_fd;
    t->out_fd = out_fd;
}

grpcdc_transport stdio_transport_iface(stdio_transport *t) {
    grpcdc_transport iface;
    iface.ctx = t;
    iface.send = stdio_send;
    iface.recv = stdio_recv;
    iface.recv_until = stdio_recv_until;
    return iface;
}
