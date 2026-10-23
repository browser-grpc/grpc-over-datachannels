/* Dynamic (descriptor-driven) client support for the C runtime:
   schemas are consumed as data at runtime (a FileDescriptorSet
   produced by protoc), with a generic protobuf codec that retains
   unknown fields. No generated stubs are involved; method paths,
   field numbers and streaming shapes all come from the parsed
   descriptors. Mirrors the dynamic clients in the other runtimes.
*/
#ifndef GRPCDC_DYNAMIC_H
#define GRPCDC_DYNAMIC_H

#include <stddef.h>
#include <stdint.h>

#include "grpcdc/grpcdc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- parsed schema ---- */

typedef struct {
    char *name;
    int32_t number;
    int32_t label; /* 1 optional, 2 required, 3 repeated */
    int32_t type;  /* FieldDescriptorProto.Type */
    char *type_name; /* for message/enum fields, else NULL */
} grpcdc_dyn_field;

typedef struct {
    char *full_name; /* ".echo.EchoRequest" */
    grpcdc_dyn_field *fields;
    size_t field_count;
} grpcdc_dyn_message;

typedef struct {
    char *name;
    char *input_type;  /* ".echo.EchoRequest" */
    char *output_type; /* ".echo.EchoResponse" */
    int client_streaming;
    int server_streaming;
} grpcdc_dyn_method;

typedef struct {
    char *full_name; /* ".echo.Echo" */
    grpcdc_dyn_method *methods;
    size_t method_count;
} grpcdc_dyn_service;

typedef struct {
    grpcdc_dyn_message *messages;
    size_t message_count;
    grpcdc_dyn_service *services;
    size_t service_count;
} grpcdc_dyn_schema;

/* Parse a FileDescriptorSet (protoc --descriptor_set_out). Returns
   NULL on malformed input. */
grpcdc_dyn_schema *grpcdc_dyn_schema_parse(const uint8_t *data, size_t len);
void grpcdc_dyn_schema_free(grpcdc_dyn_schema *schema);

const grpcdc_dyn_message *grpcdc_dyn_find_message(
    const grpcdc_dyn_schema *schema, const char *full_name);
const grpcdc_dyn_service *grpcdc_dyn_find_service(
    const grpcdc_dyn_schema *schema, const char *full_name);
const grpcdc_dyn_method *grpcdc_dyn_find_method(
    const grpcdc_dyn_service *service, const char *name);
const grpcdc_dyn_field *grpcdc_dyn_find_field(
    const grpcdc_dyn_message *message, const char *name);

/* "/echo.Echo/Unary" style path for a method (malloc'd). */
char *grpcdc_dyn_method_path(const grpcdc_dyn_service *service,
                             const grpcdc_dyn_method *method);

/* ---- generic message ---- */

typedef struct {
    int32_t number;
    int wire_type; /* 0 varint, 1 i64, 2 len, 5 i32 */
    uint64_t varint;
    uint8_t *bytes; /* owned; for wire_type 2 */
    size_t bytes_len;
    uint64_t fixed; /* for wire types 1 and 5 */
} grpcdc_dyn_entry;

typedef struct {
    grpcdc_dyn_entry *entries;
    size_t count;
    size_t cap;
} grpcdc_dyn_msg;

void grpcdc_dyn_msg_init(grpcdc_dyn_msg *msg);
void grpcdc_dyn_msg_free(grpcdc_dyn_msg *msg);

/* Decode raw message bytes into entries (wire order preserved, so
   re-encoding retains unknown fields byte-for-byte). */
int grpcdc_dyn_msg_decode(grpcdc_dyn_msg *msg, const uint8_t *data,
                          size_t len);
grpcdc_bytes grpcdc_dyn_msg_encode(const grpcdc_dyn_msg *msg);

/* Typed access by field descriptor. Set replaces any existing
   entry for the field (singular semantics). */
void grpcdc_dyn_msg_set_string(grpcdc_dyn_msg *msg,
                               const grpcdc_dyn_field *field,
                               const char *value);
void grpcdc_dyn_msg_set_varint(grpcdc_dyn_msg *msg,
                               const grpcdc_dyn_field *field, uint64_t value);
/* Returns 1 when present. Strings are NUL-terminated copies owned
   by the caller (free with grpcdc_dyn_string_free). */
int grpcdc_dyn_msg_get_string(const grpcdc_dyn_msg *msg,
                              const grpcdc_dyn_field *field, char **out);
int grpcdc_dyn_msg_get_varint(const grpcdc_dyn_msg *msg,
                              const grpcdc_dyn_field *field, uint64_t *out);
void grpcdc_dyn_string_free(char *s);

/* ---- dynamic calls over a channel ---- */

/* Unary call with generic messages. On success *resp holds the
   decoded response message. */
grpcdc_status grpcdc_dyn_unary(grpcdc_channel *ch, const char *path,
                               const grpcdc_dyn_msg *req,
                               grpcdc_dyn_msg *resp);

/* Open a stream for client-streaming/bidi shapes (send_first=0);
   use grpcdc_dyn_stream_send / grpcdc_dyn_stream_recv. */
grpcdc_status grpcdc_dyn_open(grpcdc_channel *ch, const char *path,
                              const grpcdc_kv *md, size_t md_count,
                              grpcdc_stream **out);
grpcdc_status grpcdc_dyn_stream_send(grpcdc_stream *s,
                                     const grpcdc_dyn_msg *msg);
/* 1 = message decoded into *out, 0 = clean end, -1 = *st status. */
int grpcdc_dyn_stream_recv(grpcdc_stream *s, grpcdc_dyn_msg *out,
                           grpcdc_status *st);

#ifdef __cplusplus
}
#endif

#endif /* GRPCDC_DYNAMIC_H */
