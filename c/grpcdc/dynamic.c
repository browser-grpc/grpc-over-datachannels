#include "grpcdc/dynamic.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- wire cursor ---- */

typedef struct {
    const uint8_t *buf;
    size_t len;
    size_t pos;
    int ok;
} cursor;

static uint64_t cur_varint(cursor *c) {
    uint64_t result = 0;
    int shift = 0;
    while (c->pos < c->len && shift < 70) {
        uint8_t b = c->buf[c->pos++];
        result |= (uint64_t)(b & 0x7f) << shift;
        if ((b & 0x80) == 0) return result;
        shift += 7;
    }
    c->ok = 0;
    return 0;
}

static const uint8_t *cur_bytes(cursor *c, size_t *out_len) {
    uint64_t n = cur_varint(c);
    if (!c->ok || c->pos + n > c->len) {
        c->ok = 0;
        return NULL;
    }
    const uint8_t *p = c->buf + c->pos;
    c->pos += (size_t)n;
    *out_len = (size_t)n;
    return p;
}

static uint64_t cur_fixed(cursor *c, int nbytes) {
    uint64_t v = 0;
    for (int i = 0; i < nbytes; i++) {
        if (c->pos >= c->len) {
            c->ok = 0;
            return 0;
        }
        v |= (uint64_t)c->buf[c->pos++] << (8 * i);
    }
    return v;
}

static void cur_skip(cursor *c, int wire) {
    size_t n;
    switch (wire) {
        case 0: (void)cur_varint(c); break;
        case 1: (void)cur_fixed(c, 8); break;
        case 2: (void)cur_bytes(c, &n); break;
        case 5: (void)cur_fixed(c, 4); break;
        default: c->ok = 0; break;
    }
}

/* Next field: returns field number (>0), 0 at end, -1 on error. */
static int cur_next(cursor *c, int *wire) {
    if (!c->ok) return -1;
    if (c->pos >= c->len) return 0;
    uint64_t tag = cur_varint(c);
    if (!c->ok || tag == 0) return -1;
    *wire = (int)(tag & 7);
    return (int)(tag >> 3);
}

static char *dup_range(const uint8_t *p, size_t n) {
    char *s = (char *)malloc(n + 1);
    if (!s) return NULL;
    memcpy(s, p, n);
    s[n] = 0;
    return s;
}

/* ---- descriptor parsing (field numbers per descriptor.proto) ---- */

static void parse_field(cursor *c, grpcdc_dyn_field *f) {
    int wire;
    int num;
    while ((num = cur_next(c, &wire)) > 0) {
        size_t n;
        const uint8_t *p;
        switch (num) {
            case 1:
                if (wire == 2 && (p = cur_bytes(c, &n))) f->name = dup_range(p, n);
                else cur_skip(c, wire);
                break;
            case 3:
                if (wire == 0) f->number = (int32_t)cur_varint(c);
                else cur_skip(c, wire);
                break;
            case 4:
                if (wire == 0) f->label = (int32_t)cur_varint(c);
                else cur_skip(c, wire);
                break;
            case 5:
                if (wire == 0) f->type = (int32_t)cur_varint(c);
                else cur_skip(c, wire);
                break;
            case 6:
                if (wire == 2 && (p = cur_bytes(c, &n))) f->type_name = dup_range(p, n);
                else cur_skip(c, wire);
                break;
            default:
                cur_skip(c, wire);
                break;
        }
    }
}

static void parse_message(cursor *c, const char *package, grpcdc_dyn_message *m) {
    int wire;
    int num;
    char *name = NULL;
    while ((num = cur_next(c, &wire)) > 0) {
        size_t n;
        const uint8_t *p;
        if (num == 1 && wire == 2 && (p = cur_bytes(c, &n))) {
            name = dup_range(p, n);
        } else if (num == 2 && wire == 2 && (p = cur_bytes(c, &n))) {
            cursor sub = {p, n, 0, 1};
            m->fields = (grpcdc_dyn_field *)realloc(
                m->fields, sizeof(grpcdc_dyn_field) * (m->field_count + 1));
            grpcdc_dyn_field *f = &m->fields[m->field_count++];
            memset(f, 0, sizeof(*f));
            parse_field(&sub, f);
        } else {
            cur_skip(c, wire);
        }
    }
    if (name) {
        size_t need = strlen(package) + strlen(name) + 3;
        m->full_name = (char *)malloc(need);
        if (package && package[0])
            snprintf(m->full_name, need, ".%s.%s", package, name);
        else
            snprintf(m->full_name, need, ".%s", name);
        free(name);
    }
}

static void parse_method(cursor *c, grpcdc_dyn_method *md) {
    int wire;
    int num;
    while ((num = cur_next(c, &wire)) > 0) {
        size_t n;
        const uint8_t *p;
        switch (num) {
            case 1:
                if (wire == 2 && (p = cur_bytes(c, &n))) md->name = dup_range(p, n);
                else cur_skip(c, wire);
                break;
            case 2:
                if (wire == 2 && (p = cur_bytes(c, &n))) md->input_type = dup_range(p, n);
                else cur_skip(c, wire);
                break;
            case 3:
                if (wire == 2 && (p = cur_bytes(c, &n))) md->output_type = dup_range(p, n);
                else cur_skip(c, wire);
                break;
            case 5:
                if (wire == 0) md->client_streaming = (int)cur_varint(c);
                else cur_skip(c, wire);
                break;
            case 6:
                if (wire == 0) md->server_streaming = (int)cur_varint(c);
                else cur_skip(c, wire);
                break;
            default:
                cur_skip(c, wire);
                break;
        }
    }
}

static void parse_service(cursor *c, const char *package, grpcdc_dyn_service *svc) {
    int wire;
    int num;
    char *name = NULL;
    while ((num = cur_next(c, &wire)) > 0) {
        size_t n;
        const uint8_t *p;
        if (num == 1 && wire == 2 && (p = cur_bytes(c, &n))) {
            name = dup_range(p, n);
        } else if (num == 2 && wire == 2 && (p = cur_bytes(c, &n))) {
            cursor sub = {p, n, 0, 1};
            svc->methods = (grpcdc_dyn_method *)realloc(
                svc->methods, sizeof(grpcdc_dyn_method) * (svc->method_count + 1));
            grpcdc_dyn_method *md = &svc->methods[svc->method_count++];
            memset(md, 0, sizeof(*md));
            parse_method(&sub, md);
        } else {
            cur_skip(c, wire);
        }
    }
    if (name) {
        size_t need = strlen(package) + strlen(name) + 3;
        svc->full_name = (char *)malloc(need);
        if (package && package[0])
            snprintf(svc->full_name, need, ".%s.%s", package, name);
        else
            snprintf(svc->full_name, need, ".%s", name);
        free(name);
    }
}

static void parse_file(cursor *c, grpcdc_dyn_schema *schema) {
    int wire;
    int num;
    char *package = dup_range((const uint8_t *)"", 0);
    /* Two passes over the file body: package may follow the
       message/service entries, so collect spans first. */
    typedef struct { int num; const uint8_t *p; size_t n; } span;
    span spans[256];
    size_t span_count = 0;
    while ((num = cur_next(c, &wire)) > 0) {
        if (wire != 2) {
            cur_skip(c, wire);
            continue;
        }
        size_t n;
        const uint8_t *p = cur_bytes(c, &n);
        if (!c->ok) break;
        if (num == 2) {
            free(package);
            package = dup_range(p, n);
        }
        if ((num == 4 || num == 6) && span_count < 256) {
            spans[span_count].num = num;
            spans[span_count].p = p;
            spans[span_count].n = n;
            span_count++;
        }
    }
    for (size_t i = 0; i < span_count; i++) {
        cursor sub = {spans[i].p, spans[i].n, 0, 1};
        if (spans[i].num == 4) {
            schema->messages = (grpcdc_dyn_message *)realloc(
                schema->messages,
                sizeof(grpcdc_dyn_message) * (schema->message_count + 1));
            grpcdc_dyn_message *m = &schema->messages[schema->message_count++];
            memset(m, 0, sizeof(*m));
            parse_message(&sub, package, m);
        } else {
            schema->services = (grpcdc_dyn_service *)realloc(
                schema->services,
                sizeof(grpcdc_dyn_service) * (schema->service_count + 1));
            grpcdc_dyn_service *svc = &schema->services[schema->service_count++];
            memset(svc, 0, sizeof(*svc));
            parse_service(&sub, package, svc);
        }
    }
    free(package);
}

grpcdc_dyn_schema *grpcdc_dyn_schema_parse(const uint8_t *data, size_t len) {
    grpcdc_dyn_schema *schema =
        (grpcdc_dyn_schema *)calloc(1, sizeof(grpcdc_dyn_schema));
    if (!schema) return NULL;
    cursor c = {data, len, 0, 1};
    int wire;
    int num;
    while ((num = cur_next(&c, &wire)) > 0) {
        if (num == 1 && wire == 2) {
            size_t n;
            const uint8_t *p = cur_bytes(&c, &n);
            if (!c.ok) break;
            cursor sub = {p, n, 0, 1};
            parse_file(&sub, schema);
        } else {
            cur_skip(&c, wire);
        }
    }
    if (!c.ok) {
        grpcdc_dyn_schema_free(schema);
        return NULL;
    }
    return schema;
}

void grpcdc_dyn_schema_free(grpcdc_dyn_schema *schema) {
    if (!schema) return;
    for (size_t i = 0; i < schema->message_count; i++) {
        grpcdc_dyn_message *m = &schema->messages[i];
        free(m->full_name);
        for (size_t j = 0; j < m->field_count; j++) {
            free(m->fields[j].name);
            free(m->fields[j].type_name);
        }
        free(m->fields);
    }
    free(schema->messages);
    for (size_t i = 0; i < schema->service_count; i++) {
        grpcdc_dyn_service *svc = &schema->services[i];
        free(svc->full_name);
        for (size_t j = 0; j < svc->method_count; j++) {
            free(svc->methods[j].name);
            free(svc->methods[j].input_type);
            free(svc->methods[j].output_type);
        }
        free(svc->methods);
    }
    free(schema->services);
    free(schema);
}

const grpcdc_dyn_message *grpcdc_dyn_find_message(
    const grpcdc_dyn_schema *schema, const char *full_name) {
    for (size_t i = 0; i < schema->message_count; i++)
        if (schema->messages[i].full_name &&
            strcmp(schema->messages[i].full_name, full_name) == 0)
            return &schema->messages[i];
    return NULL;
}

const grpcdc_dyn_service *grpcdc_dyn_find_service(
    const grpcdc_dyn_schema *schema, const char *full_name) {
    for (size_t i = 0; i < schema->service_count; i++)
        if (schema->services[i].full_name &&
            strcmp(schema->services[i].full_name, full_name) == 0)
            return &schema->services[i];
    return NULL;
}

const grpcdc_dyn_method *grpcdc_dyn_find_method(
    const grpcdc_dyn_service *service, const char *name) {
    for (size_t i = 0; i < service->method_count; i++)
        if (service->methods[i].name &&
            strcmp(service->methods[i].name, name) == 0)
            return &service->methods[i];
    return NULL;
}

const grpcdc_dyn_field *grpcdc_dyn_find_field(
    const grpcdc_dyn_message *message, const char *name) {
    for (size_t i = 0; i < message->field_count; i++)
        if (message->fields[i].name &&
            strcmp(message->fields[i].name, name) == 0)
            return &message->fields[i];
    return NULL;
}

char *grpcdc_dyn_method_path(const grpcdc_dyn_service *service,
                             const grpcdc_dyn_method *method) {
    const char *svc = service->full_name;
    if (svc && svc[0] == '.') svc++;
    size_t need = strlen(svc) + strlen(method->name) + 3;
    char *path = (char *)malloc(need);
    snprintf(path, need, "/%s/%s", svc, method->name);
    return path;
}

/* ---- generic message codec ---- */

void grpcdc_dyn_msg_init(grpcdc_dyn_msg *msg) {
    memset(msg, 0, sizeof(*msg));
}

void grpcdc_dyn_msg_free(grpcdc_dyn_msg *msg) {
    for (size_t i = 0; i < msg->count; i++) free(msg->entries[i].bytes);
    free(msg->entries);
    grpcdc_dyn_msg_init(msg);
}

static grpcdc_dyn_entry *msg_push(grpcdc_dyn_msg *msg) {
    if (msg->count == msg->cap) {
        msg->cap = msg->cap ? msg->cap * 2 : 8;
        msg->entries = (grpcdc_dyn_entry *)realloc(
            msg->entries, sizeof(grpcdc_dyn_entry) * msg->cap);
    }
    grpcdc_dyn_entry *e = &msg->entries[msg->count++];
    memset(e, 0, sizeof(*e));
    return e;
}

int grpcdc_dyn_msg_decode(grpcdc_dyn_msg *msg, const uint8_t *data,
                          size_t len) {
    cursor c = {data, len, 0, 1};
    int wire;
    int num;
    while ((num = cur_next(&c, &wire)) > 0) {
        grpcdc_dyn_entry *e = msg_push(msg);
        e->number = num;
        e->wire_type = wire;
        switch (wire) {
            case 0:
                e->varint = cur_varint(&c);
                break;
            case 1:
                e->fixed = cur_fixed(&c, 8);
                break;
            case 5:
                e->fixed = cur_fixed(&c, 4);
                break;
            case 2: {
                size_t n;
                const uint8_t *p = cur_bytes(&c, &n);
                if (!p) return 0;
                e->bytes = (uint8_t *)malloc(n ? n : 1);
                memcpy(e->bytes, p, n);
                e->bytes_len = n;
                break;
            }
            default:
                return 0;
        }
        if (!c.ok) return 0;
    }
    return c.ok;
}

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} writer;

static void wr_reserve(writer *w, size_t n) {
    if (w->len + n > w->cap) {
        size_t cap = w->cap ? w->cap : 64;
        while (cap < w->len + n) cap *= 2;
        w->data = (uint8_t *)realloc(w->data, cap);
        w->cap = cap;
    }
}

static void wr_varint(writer *w, uint64_t v) {
    wr_reserve(w, 10);
    while (v > 0x7f) {
        w->data[w->len++] = (uint8_t)((v & 0x7f) | 0x80);
        v >>= 7;
    }
    w->data[w->len++] = (uint8_t)v;
}

static void wr_bytes(writer *w, const uint8_t *p, size_t n) {
    wr_reserve(w, n);
    if (n) memcpy(w->data + w->len, p, n);
    w->len += n;
}

grpcdc_bytes grpcdc_dyn_msg_encode(const grpcdc_dyn_msg *msg) {
    writer w = {0};
    for (size_t i = 0; i < msg->count; i++) {
        const grpcdc_dyn_entry *e = &msg->entries[i];
        wr_varint(&w, ((uint64_t)e->number << 3) | (uint64_t)e->wire_type);
        switch (e->wire_type) {
            case 0:
                wr_varint(&w, e->varint);
                break;
            case 1:
                wr_reserve(&w, 8);
                for (int b = 0; b < 8; b++)
                    w.data[w.len++] = (uint8_t)(e->fixed >> (8 * b));
                break;
            case 5:
                wr_reserve(&w, 4);
                for (int b = 0; b < 4; b++)
                    w.data[w.len++] = (uint8_t)(e->fixed >> (8 * b));
                break;
            case 2:
                wr_varint(&w, e->bytes_len);
                wr_bytes(&w, e->bytes, e->bytes_len);
                break;
        }
    }
    grpcdc_bytes out;
    out.data = w.data;
    out.len = w.len;
    return out;
}

static grpcdc_dyn_entry *msg_find(grpcdc_dyn_msg *msg, int32_t number) {
    for (size_t i = 0; i < msg->count; i++)
        if (msg->entries[i].number == number) return &msg->entries[i];
    return NULL;
}

static void msg_set(grpcdc_dyn_msg *msg, const grpcdc_dyn_field *field,
                    int wire, uint64_t varint, const uint8_t *bytes,
                    size_t bytes_len) {
    grpcdc_dyn_entry *e = msg_find(msg, field->number);
    if (!e) e = msg_push(msg);
    free(e->bytes);
    e->bytes = NULL;
    e->bytes_len = 0;
    e->number = field->number;
    e->wire_type = wire;
    e->varint = varint;
    if (wire == 2) {
        e->bytes = (uint8_t *)malloc(bytes_len ? bytes_len : 1);
        memcpy(e->bytes, bytes, bytes_len);
        e->bytes_len = bytes_len;
    }
}

void grpcdc_dyn_msg_set_string(grpcdc_dyn_msg *msg,
                               const grpcdc_dyn_field *field,
                               const char *value) {
    msg_set(msg, field, 2, 0, (const uint8_t *)value, strlen(value));
}

void grpcdc_dyn_msg_set_varint(grpcdc_dyn_msg *msg,
                               const grpcdc_dyn_field *field, uint64_t value) {
    msg_set(msg, field, 0, value, NULL, 0);
}

int grpcdc_dyn_msg_get_string(const grpcdc_dyn_msg *msg,
                              const grpcdc_dyn_field *field, char **out) {
    const grpcdc_dyn_entry *e = NULL;
    for (size_t i = 0; i < msg->count; i++)
        if (msg->entries[i].number == field->number) e = &msg->entries[i];
    if (!e || e->wire_type != 2) return 0;
    *out = dup_range(e->bytes, e->bytes_len);
    return 1;
}

int grpcdc_dyn_msg_get_varint(const grpcdc_dyn_msg *msg,
                              const grpcdc_dyn_field *field, uint64_t *out) {
    const grpcdc_dyn_entry *e = NULL;
    for (size_t i = 0; i < msg->count; i++)
        if (msg->entries[i].number == field->number) e = &msg->entries[i];
    if (!e || e->wire_type != 0) return 0;
    *out = e->varint;
    return 1;
}

void grpcdc_dyn_string_free(char *s) { free(s); }

/* ---- dynamic calls ---- */

grpcdc_status grpcdc_dyn_unary(grpcdc_channel *ch, const char *path,
                               const grpcdc_dyn_msg *req,
                               grpcdc_dyn_msg *resp) {
    grpcdc_bytes rb = grpcdc_dyn_msg_encode(req);
    grpcdc_bytes out;
    grpcdc_status st = grpcdc_channel_unary(ch, path, rb.data, rb.len, NULL,
                                            0, 0, &out);
    free(rb.data);
    if (!grpcdc_status_is_ok(st)) return st;
    int ok = grpcdc_dyn_msg_decode(resp, out.data, out.len);
    grpcdc_bytes_free(&out);
    if (!ok)
        return grpcdc_status_make(GRPCDC_INTERNAL, "dynamic decode failed");
    return grpcdc_ok();
}

grpcdc_status grpcdc_dyn_open(grpcdc_channel *ch, const char *path,
                              const grpcdc_kv *md, size_t md_count,
                              grpcdc_stream **out) {
    return grpcdc_channel_open(ch, path, NULL, 0, 0, md, md_count, 0, out);
}

grpcdc_status grpcdc_dyn_stream_send(grpcdc_stream *s,
                                     const grpcdc_dyn_msg *msg) {
    grpcdc_bytes rb = grpcdc_dyn_msg_encode(msg);
    grpcdc_status st = grpcdc_stream_send(s, rb.data, rb.len);
    free(rb.data);
    return st;
}

int grpcdc_dyn_stream_recv(grpcdc_stream *s, grpcdc_dyn_msg *out,
                           grpcdc_status *st) {
    grpcdc_bytes raw;
    int r = grpcdc_stream_recv(s, &raw, st);
    if (r != 1) return r;
    int ok = grpcdc_dyn_msg_decode(out, raw.data, raw.len);
    grpcdc_bytes_free(&raw);
    if (!ok) {
        *st = grpcdc_status_make(GRPCDC_INTERNAL, "dynamic decode failed");
        return -1;
    }
    *st = grpcdc_ok();
    return 1;
}
