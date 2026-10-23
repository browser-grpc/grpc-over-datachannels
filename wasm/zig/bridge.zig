//! Bridge runtime for the generated WASM client facades
//! (echo_wasm_dc.zig): hands protobuf payloads to the page's
//! JS grpc-dc bridge (js/src/wasm_bridge.js) via imports, and
//! receives responses through the exported on_bridge_* hooks.
//! The JS implementation owns the wire; this file owns only
//! the interop. Mirrors wasm/go/bridge.go, callback-shaped
//! because wasm32-freestanding is single-threaded.
//!
//! Import contract (page side): every js_* import copies the
//! payload bytes out of WASM memory synchronously, so callers
//! may free them as soon as the import returns. Multi-payload
//! calls pack payloads as u32be length-prefixed chunks.

const std = @import("std");
const status_mod = @import("grpcdc_status");

pub const Status = status_mod.Status;
pub const CompleteFn = *const fn (ctx: *anyopaque, status: Status, payload: ?[]const u8) void;
pub const MessageFn = *const fn (ctx: *anyopaque, payload: []const u8) void;

extern "env" fn js_unary(call_id: u32, path_ptr: [*]const u8, path_len: usize, payload_ptr: [*]const u8, payload_len: usize) void;
extern "env" fn js_unary_opts(call_id: u32, path_ptr: [*]const u8, path_len: usize, payload_ptr: [*]const u8, payload_len: usize, opts_ptr: [*]const u8, opts_len: usize) void;
extern "env" fn js_server_stream(call_id: u32, path_ptr: [*]const u8, path_len: usize, payload_ptr: [*]const u8, payload_len: usize) void;
extern "env" fn js_server_stream_cancel(call_id: u32, path_ptr: [*]const u8, path_len: usize, payload_ptr: [*]const u8, payload_len: usize, cancel_after: u32) void;
extern "env" fn js_client_stream(call_id: u32, path_ptr: [*]const u8, path_len: usize, packed_ptr: [*]const u8, packed_len: usize) void;
extern "env" fn js_bidi(call_id: u32, path_ptr: [*]const u8, path_len: usize, packed_ptr: [*]const u8, packed_len: usize) void;

const Entry = struct {
    ctx: *anyopaque,
    on_message: ?MessageFn,
    complete: CompleteFn,
};

var g_alloc: ?std.mem.Allocator = null;
var g_pending: ?std.AutoHashMap(u32, Entry) = null;
var g_next_id: u32 = 1;

fn alloc() std.mem.Allocator {
    return g_alloc.?;
}

fn pending() *std.AutoHashMap(u32, Entry) {
    return &g_pending.?;
}

pub const Bridge = struct {
    alloc: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        if (g_alloc == null) {
            g_alloc = allocator;
            g_pending = std.AutoHashMap(u32, Entry).init(allocator);
        }
        return .{ .alloc = allocator };
    }

    fn register(self: *Bridge, entry: Entry) u32 {
        _ = self;
        const id = g_next_id;
        g_next_id += 1;
        pending().put(id, entry) catch {};
        return id;
    }

    // Options-aware unary: optsJson is forwarded by the page
    // to the JS bridge ({metadata, timeout}).
    pub fn unaryWithOptions(self: *Bridge, path: []const u8, payload: []const u8, opts_json: []const u8, ctx: *anyopaque, complete: CompleteFn) void {
        const id = self.register(.{ .ctx = ctx, .on_message = null, .complete = complete });
        js_unary_opts(id, path.ptr, path.len, payload.ptr, payload.len, opts_json.ptr, opts_json.len);
    }

    // Server-streaming call torn down after cancelAfter
    // responses; completes normally.
    pub fn serverStreamCancelAfter(self: *Bridge, path: []const u8, payload: []const u8, cancel_after: u32, ctx: *anyopaque, on_message: MessageFn, complete: CompleteFn) void {
        const id = self.register(.{ .ctx = ctx, .on_message = on_message, .complete = complete });
        js_server_stream_cancel(id, path.ptr, path.len, payload.ptr, payload.len, cancel_after);
    }

    pub fn unary(self: *Bridge, path: []const u8, payload: []const u8, ctx: *anyopaque, complete: CompleteFn) void {
        const id = self.register(.{ .ctx = ctx, .on_message = null, .complete = complete });
        js_unary(id, path.ptr, path.len, payload.ptr, payload.len);
    }

    pub fn serverStream(self: *Bridge, path: []const u8, payload: []const u8, ctx: *anyopaque, on_message: MessageFn, complete: CompleteFn) void {
        const id = self.register(.{ .ctx = ctx, .on_message = on_message, .complete = complete });
        js_server_stream(id, path.ptr, path.len, payload.ptr, payload.len);
    }

    pub fn clientStream(self: *Bridge, path: []const u8, payloads: []const []const u8, ctx: *anyopaque, complete: CompleteFn) void {
        const id = self.register(.{ .ctx = ctx, .on_message = null, .complete = complete });
        const packed_buf = pack(payloads);
        defer alloc().free(packed_buf);
        js_client_stream(id, path.ptr, path.len, packed_buf.ptr, packed_buf.len);
    }

    pub fn bidi(self: *Bridge, path: []const u8, payloads: []const []const u8, ctx: *anyopaque, on_message: MessageFn, complete: CompleteFn) void {
        const id = self.register(.{ .ctx = ctx, .on_message = on_message, .complete = complete });
        const packed_buf = pack(payloads);
        defer alloc().free(packed_buf);
        js_bidi(id, path.ptr, path.len, packed_buf.ptr, packed_buf.len);
    }
};

fn pack(payloads: []const []const u8) []u8 {
    var total: usize = 0;
    for (payloads) |p| total += 4 + p.len;
    const buf = alloc().alloc(u8, total) catch return &.{};
    var pos: usize = 0;
    for (payloads) |p| {
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(p.len), .big);
        pos += 4;
        @memcpy(buf[pos..][0..p.len], p);
        pos += p.len;
    }
    return buf;
}

// ---- exports used by the page glue ----

export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = alloc().alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    alloc().free(ptr[0..len]);
}

export fn on_bridge_message(call_id: u32, ptr: [*]u8, len: usize) void {
    defer wasm_free(ptr, len);
    if (pending().get(call_id)) |entry| {
        if (entry.on_message) |on_message| on_message(entry.ctx, ptr[0..len]);
    }
}

export fn on_bridge_done(call_id: u32, has_payload: u32, ptr: [*]u8, len: usize) void {
    defer if (len > 0) wasm_free(ptr, len);
    if (pending().fetchRemove(call_id)) |kv| {
        const payload: ?[]const u8 = if (has_payload != 0) ptr[0..len] else null;
        kv.value.complete(kv.value.ctx, Status.ok(), payload);
    }
}

// ---- server side: generated serve_* exports report through
// these imports to the page glue, which owns the JS server
// bridge (createGrpcDcServerBridge). ----

extern "env" fn js_server_respond(call_id: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn js_server_send(call_id: u32, ptr: [*]const u8, len: usize) void;
extern "env" fn js_server_complete(call_id: u32) void;
extern "env" fn js_server_fail(call_id: u32, code: i32, ptr: [*]const u8, len: usize) void;

// Allocator accessor for generated serve_* exports.
pub fn bridgeAllocator() std.mem.Allocator {
    return alloc();
}

pub fn serverRespond(call_id: u32, payload: []const u8) void {
    js_server_respond(call_id, payload.ptr, payload.len);
}

pub fn serverSend(call_id: u32, payload: []const u8) void {
    js_server_send(call_id, payload.ptr, payload.len);
}

pub fn serverComplete(call_id: u32) void {
    js_server_complete(call_id);
}

pub fn serverFail(call_id: u32, status: Status) void {
    js_server_fail(call_id, status.code, status.message.ptr, status.message.len);
}

// Split a u32be length-prefixed packed buffer (no copies).
pub fn unpack(allocator: std.mem.Allocator, data: []const u8) ![][]const u8 {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos + 4 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4 + len;
        count += 1;
    }
    const out = try allocator.alloc([]const u8, count);
    pos = 0;
    var i: usize = 0;
    while (pos + 4 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        out[i] = data[pos..][0..len];
        pos += len;
        i += 1;
    }
    return out;
}

/// One metadata key/value pair (views into the packed buffer).
pub const MdPair = struct { key: []const u8, value: []const u8 };

// Decode flattened [key, value, ...] packed metadata.
pub fn decodeMetadata(allocator: std.mem.Allocator, data: []const u8) ![]MdPair {
    const flat = try unpack(allocator, data);
    defer allocator.free(flat);
    const out = try allocator.alloc(MdPair, flat.len / 2);
    var i: usize = 0;
    while (i + 1 < flat.len) : (i += 2) {
        out[i / 2] = .{ .key = flat[i], .value = flat[i + 1] };
    }
    return out;
}

pub fn metadataGet(pairs: []const MdPair, key: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair.value;
    }
    return null;
}

export fn on_bridge_error(call_id: u32, code: i32, ptr: [*]u8, len: usize) void {
    defer if (len > 0) wasm_free(ptr, len);
    if (pending().fetchRemove(call_id)) |kv| {
        const message = alloc().dupe(u8, ptr[0..len]) catch "";
        defer if (message.len > 0) alloc().free(message);
        kv.value.complete(kv.value.ctx, Status.init(code, message), null);
    }
}
