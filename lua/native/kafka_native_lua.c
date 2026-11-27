/* kafka_native_core: Lua C bridge to libkafka_native.
 *
 * Thin marshalling only: every call passes a method name and
 * protobuf-encoded request bytes to kafka_native_call (or
 * the stream triple) and returns response bytes. All Kafka
 * protocol logic stays in the Rust kafka-service crate.
 *
 * Build (Lua 5.4):
 *   cc -O2 -fPIC -shared -I/usr/include/lua5.4 \
 *      lua/native/kafka_native_lua.c \
 *      -L<kafka-native lib dir> -lkafka_native \
 *      -o kafka_native_core.so
 * The Lua wrapper (grpcdc/kafka_native.lua) locates it via
 * package.cpath; the library itself via
 * GRPC_DC_KAFKA_NATIVE_LIB at wrapper level (dlopen path is
 * resolved by the dynamic loader, so LD_LIBRARY_PATH or an
 * rpath must find libkafka_native).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

typedef struct KafkaNativeHandle KafkaNativeHandle;
typedef struct KafkaNativeStream KafkaNativeStream;

extern KafkaNativeHandle *kafka_native_new(const char *broker, const char *client_id);
extern void kafka_native_free(KafkaNativeHandle *handle);
extern int kafka_native_call(KafkaNativeHandle *handle, const char *method,
                             const uint8_t *req, size_t req_len,
                             uint8_t **out, size_t *out_len);
extern KafkaNativeStream *kafka_native_stream_new(KafkaNativeHandle *handle,
                                                  const char *method,
                                                  const uint8_t *req, size_t req_len);
extern int kafka_native_stream_next(KafkaNativeStream *stream,
                                    uint8_t **out, size_t *out_len);
extern void kafka_native_stream_free(KafkaNativeStream *stream);
extern void kafka_native_bytes_free(uint8_t *ptr, size_t len);
extern const char *kafka_native_last_error(void);

#define HANDLE_MT "kafka_native.handle"
#define STREAM_MT "kafka_native.stream"

static KafkaNativeHandle **check_handle(lua_State *L, int idx) {
    return (KafkaNativeHandle **)luaL_checkudata(L, idx, HANDLE_MT);
}

static KafkaNativeStream **check_stream(lua_State *L, int idx) {
    return (KafkaNativeStream **)luaL_checkudata(L, idx, STREAM_MT);
}

static int l_new(lua_State *L) {
    const char *broker = luaL_checkstring(L, 1);
    const char *client_id = luaL_optstring(L, 2, "grpc-dc-kafka-native");
    KafkaNativeHandle *h = kafka_native_new(broker, client_id);
    if (h == NULL) {
        lua_pushnil(L);
        return 1;
    }
    KafkaNativeHandle **ud = (KafkaNativeHandle **)lua_newuserdatauv(L, sizeof(*ud), 0);
    *ud = h;
    luaL_setmetatable(L, HANDLE_MT);
    return 1;
}

static int l_handle_gc(lua_State *L) {
    KafkaNativeHandle **ud = (KafkaNativeHandle **)luaL_testudata(L, 1, HANDLE_MT);
    if (ud != NULL && *ud != NULL) {
        kafka_native_free(*ud);
        *ud = NULL;
    }
    return 0;
}

static int l_close(lua_State *L) {
    return l_handle_gc(L);
}

static int l_call(lua_State *L) {
    KafkaNativeHandle *h = *check_handle(L, 1);
    const char *method = luaL_checkstring(L, 2);
    size_t req_len = 0;
    const char *req = luaL_checklstring(L, 3, &req_len);
    uint8_t *out = NULL;
    size_t out_len = 0;
    int rc = kafka_native_call(h, method, (const uint8_t *)req, req_len, &out, &out_len);
    if (rc != 0) {
        lua_pushnil(L);
        return 1;
    }
    if (out == NULL) {
        lua_pushlstring(L, "", 0);
        return 1;
    }
    lua_pushlstring(L, (const char *)out, out_len);
    kafka_native_bytes_free(out, out_len);
    return 1;
}

static int l_stream_new(lua_State *L) {
    KafkaNativeHandle *h = *check_handle(L, 1);
    const char *method = luaL_checkstring(L, 2);
    size_t req_len = 0;
    const char *req = luaL_checklstring(L, 3, &req_len);
    KafkaNativeStream *s = kafka_native_stream_new(h, method, (const uint8_t *)req, req_len);
    if (s == NULL) {
        lua_pushnil(L);
        return 1;
    }
    KafkaNativeStream **ud = (KafkaNativeStream **)lua_newuserdatauv(L, sizeof(*ud), 0);
    *ud = s;
    luaL_setmetatable(L, STREAM_MT);
    return 1;
}

static int l_stream_gc(lua_State *L) {
    KafkaNativeStream **ud = (KafkaNativeStream **)luaL_testudata(L, 1, STREAM_MT);
    if (ud != NULL && *ud != NULL) {
        kafka_native_stream_free(*ud);
        *ud = NULL;
    }
    return 0;
}

static int l_stream_next(lua_State *L) {
    KafkaNativeStream *s = *check_stream(L, 1);
    uint8_t *out = NULL;
    size_t out_len = 0;
    int rc = kafka_native_stream_next(s, &out, &out_len);
    if (rc == 0) {
        lua_pushnil(L);
        return 1;
    }
    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, kafka_native_last_error());
        return 2;
    }
    if (out == NULL) {
        lua_pushlstring(L, "", 0);
        return 1;
    }
    lua_pushlstring(L, (const char *)out, out_len);
    kafka_native_bytes_free(out, out_len);
    return 1;
}

static int l_last_error(lua_State *L) {
    const char *err = kafka_native_last_error();
    lua_pushstring(L, err != NULL ? err : "kafka-native error");
    return 1;
}

static const luaL_Reg lib[] = {
    {"new", l_new},
    {"call", l_call},
    {"stream_new", l_stream_new},
    {"stream_next", l_stream_next},
    {"close", l_close},
    {"last_error", l_last_error},
    {NULL, NULL},
};

int luaopen_kafka_native_core(lua_State *L) {
    if (luaL_newmetatable(L, HANDLE_MT)) {
        lua_pushcfunction(L, l_handle_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    if (luaL_newmetatable(L, STREAM_MT)) {
        lua_pushcfunction(L, l_stream_gc);
        lua_setfield(L, -2, "__gc");
    }
    lua_pop(L, 1);
    luaL_newlib(L, lib);
    return 1;
}
