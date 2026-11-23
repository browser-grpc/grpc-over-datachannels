#lang racket

;;; runtime-zig.rkt — the Zig gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under zig/grpcdc/ are GENERATED from the bodies
;;; below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)
;;;
;;; Zig stdlib only — no external packages. Zig has no exceptions, so
;;; statuses are values (Status / CallResult / RecvResult unions).

(require "spec.rkt")
(provide emit-zig-runtime-files)

(define zig-status-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");

/// A gRPC status (code + message), carried as a value: Zig has no
/// exceptions, so fallible runtime calls return Status (codeOk means
/// success) or a result union embedding one. Mirrors StatusException
/// in the other grpcdc runtimes.
/// One trailing-metadata key/value pair.
pub const TrailerPair = struct { key: []const u8, value: []const u8 };

pub const Status = struct {
    code: i32 = wire.codeOk,
    /// Trailing metadata carried by a status frame. Owned like
    /// the message (freed by the owning event's deinit); empty
    /// when the peer sent none.
    trailers: []const TrailerPair = &.{},
    /// Borrowed or allocator-owned depending on the producer; statuses
    /// parsed from the wire own their message via the stream queue and
    /// stay valid until the owning event is consumed and freed.
    message: []const u8 = "",

    pub fn ok() Status {
        return .{};
    }

    pub fn init(code: i32, message: []const u8) Status {
        return .{ .code = code, .message = message };
    }

    pub fn isOk(self: Status) bool {
        return self.code == wire.codeOk;
    }
};

/// Outcome of one receive into a message slot.
pub const RecvOutcome = union(enum) {
    message,
    end,
    status: Status,
};

/// Result of a call producing a value (the Zig stand-in for the
/// other runtimes' value-or-StatusException split).
pub fn CallResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        status: Status,
    };
}

/// Terminal outcome of a receive: a message arrived, the call ended
/// cleanly (EndOfStream in the other runtimes), or it failed.
pub fn RecvResult(comptime T: type) type {
    return union(enum) {
        message: T,
        end,
        status: Status,
    };
}

// --- Homegrown tracing@@TRACING_BETA@@ (W3C traceparent propagation) -------------
// Dormant until setTracer registers an observer. Generated code
// stays dependency-free: sampling and export are the app's problem.

pub const TraceContext = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: [16]u8,
    has_parent: bool = false,
    sampled: bool = true,
    start_ms: i64 = 0,
};

pub const Tracer = struct {
    ctx: *anyopaque,
    on_start: *const fn (ctx: *anyopaque, kind: []const u8, method: []const u8, trace_id: []const u8, span_id: []const u8, parent_span_id: []const u8) void,
    on_end: *const fn (ctx: *anyopaque, kind: []const u8, method: []const u8, trace_id: []const u8, span_id: []const u8, status: []const u8, duration_ms: f64) void,
};

var tracer: ?Tracer = null;

pub fn setTracer(t: ?Tracer) void {
    tracer = t;
}

pub fn tracingEnabled() bool {
    return tracer != null;
}

var trace_filter_buf: [512]u8 = undefined;
var trace_filter_len: usize = 0;

// Restrict traced methods: ';'-separated paths, a trailing
// '*' means prefix match ('/echo.Echo/*'). Empty = trace all.
pub fn setTraceFilter(patterns: []const u8) void {
    const n = @min(patterns.len, trace_filter_buf.len);
    @memcpy(trace_filter_buf[0..n], patterns[0..n]);
    trace_filter_len = n;
}

fn traceAllowed(method: []const u8) bool {
    if (trace_filter_len == 0) return true;
    var it = std.mem.splitScalar(u8, trace_filter_buf[0..trace_filter_len], ';');
    while (it.next()) |p| {
        if (p.len == 0) continue;
        if (p[p.len - 1] == '*') {
            if (std.mem.startsWith(u8, method, p[0 .. p.len - 1])) return true;
        } else if (std.mem.eql(u8, method, p)) {
            return true;
        }
    }
    return false;
}

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + (v - 10);
}

var rng_state: u64 = 0;

// Time/counter-seeded xorshift (std.crypto.random needs getrandom,
// which wasm32-freestanding lacks; never use these ids for security).
fn randomHex(comptime n: usize) [n * 2]u8 {
    var state = rng_state;
    if (state == 0) {
        // No clock on freestanding targets; seed from our own address.
        state = 0x9e3779b97f4a7c15 ^ @as(u64, @intCast(@intFromPtr(&rng_state)));
    }
    var out: [n * 2]u8 = undefined;
    for (0..n) |i| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const b: u8 = @truncate(state >> 32);
        out[i * 2] = hexDigit(b >> 4);
        out[i * 2 + 1] = hexDigit(b & 0xf);
    }
    rng_state = state;
    return out;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

pub const Parent = struct {
    trace_id: []const u8,
    span_id: []const u8,
    sampled: bool = true,
};

fn traceNowMs() i64 {
    if (comptime builtin.single_threaded) return 0;
    return std.time.milliTimestamp();
}

pub fn parseTraceparent(value: ?[]const u8) ?Parent {
    const v = value orelse return null;
    var it = std.mem.splitScalar(u8, v, '-');
    _ = it.next() orelse return null;
    const trace_id = it.next() orelse return null;
    const span_id = it.next() orelse return null;
    const flags = it.next() orelse return null;
    if (trace_id.len != 32 or span_id.len != 16) return null;
    if (!isHex(trace_id) or !isHex(span_id)) return null;
    if (flags.len != 2 or !isHex(flags)) return null;
    const flag_value = std.fmt.parseInt(u8, flags, 16) catch return null;
    return .{ .trace_id = trace_id, .span_id = span_id, .sampled = (flag_value & 1) == 1 };
}

pub fn formatTraceparent(buf: *[55]u8, trace_id: []const u8, span_id: []const u8, sampled: bool) []const u8 {
    @memcpy(buf[0..3], "00-");
    @memcpy(buf[3..35], trace_id[0..32]);
    buf[35] = '-';
    @memcpy(buf[36..52], span_id[0..16]);
    @memcpy(buf[52..55], if (sampled) "-01" else "-00");
    return buf;
}

pub fn traceStart(kind: []const u8, method: []const u8, parent: ?Parent) ?TraceContext {
    const t = tracer orelse return null;
    if (!traceAllowed(method)) return null;
    var ctx = TraceContext{
        .trace_id = undefined,
        .span_id = randomHex(8),
        .parent_span_id = undefined,
        .has_parent = parent != null,
    };
    if (parent) |p| {
        @memcpy(&ctx.trace_id, p.trace_id[0..32]);
        @memcpy(&ctx.parent_span_id, p.span_id[0..16]);
    } else {
        ctx.trace_id = randomHex(16);
        ctx.parent_span_id = [_]u8{' '} ** 16;
    }
    ctx.sampled = if (parent) |par| par.sampled else true;
    ctx.start_ms = traceNowMs();
    if (!ctx.sampled) return ctx;
    const parent_span: []const u8 = if (ctx.has_parent) &ctx.parent_span_id else "";
    t.on_start(t.ctx, kind, method, &ctx.trace_id, &ctx.span_id, parent_span);
    return ctx;
}

/// Start a root span context (client workflows). Pair with traceEnd.
pub fn newTraceContext(kind: []const u8, method: []const u8) ?TraceContext {
    return traceStart(kind, method, null);
}

/// View a span context as a traceparent parent for an outbound
/// call. The slices borrow ctx, which must outlive the traceStart
/// call (span contexts stored on a Channel or CallContext do).
pub fn parentOf(ctx: ?*const TraceContext) ?Parent {
    const c = ctx orelse return null;
    return .{ .trace_id = &c.trace_id, .span_id = &c.span_id, .sampled = c.sampled };
}

pub fn traceEnd(kind: []const u8, method: []const u8, ctx: ?TraceContext, status: []const u8) void {
    const t = tracer orelse return;
    const c = ctx orelse return;
    if (!c.sampled) return;
    const duration_ms: f64 = if (c.start_ms == 0) 0 else @floatFromInt(traceNowMs() - c.start_ms);
    t.on_end(t.ctx, kind, method, &c.trace_id, &c.span_id, status, duration_ms);
}
GRPC_RUNTIME_EOF
)

(define zig-codec-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const wire = @import("wire.zig");
const status_mod = @import("status.zig");

pub const Status = status_mod.Status;

/// Parsed HEADERS payload: path == null means response headers.
pub const Headers = struct {
    path: ?[]const u8 = null,
    metadata: std.StringHashMap([]const u8),
};

/// Marshal msg with the codec selected for a call (struct layout
/// when negotiated). Messages generated without struct_codec=true
/// have no marshalStruct and panic here, mirroring the Go
/// runtime's "message has no struct codec" as a programming error.
pub fn marshalForCodec(alloc: std.mem.Allocator, struct_codec: bool, msg: anytype) []u8 {
    const T = @TypeOf(msg);
    const Child = switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
    const ptr = if (@typeInfo(T) == .pointer) msg else &msg;
    if (struct_codec) {
        if (@hasDecl(Child, "marshalStruct")) {
            return ptr.marshalStruct(alloc);
        }
        @panic("message has no struct codec");
    }
    return ptr.marshalDc(alloc);
}

/// Decode data into msg (a pointer) with the codec selected for a call.
pub fn unmarshalForCodec(struct_codec: bool, alloc: std.mem.Allocator, data: []const u8, msg: anytype) void {
    const T = @TypeOf(msg);
    const Child = switch (@typeInfo(T)) {
        .pointer => |ptr| ptr.child,
        else => T,
    };
    if (struct_codec) {
        if (@hasDecl(Child, "unmarshalStruct")) {
            msg.unmarshalStruct(alloc, data);
            return;
        }
        @panic("message has no struct codec");
    }
    msg.unmarshalDc(alloc, data);
}

/// Frame codec for gRPC over WebRTC DataChannels (wire protocol in
/// ../SPEC.md). Frame, status, channel and server semantics mirror the
/// other grpcdc runtimes; the tables in wire.zig are stamped by the
/// grpc-dc codegen.
pub const Codec = struct {
    pub const header_len: usize = 9;
    pub const max_data_payload: usize = 16 * 1024 * 1024;

    /// HEADERS metadata key a client sends to request the struct codec for a call.
    pub const struct_codec_header: []const u8 = "dc-codec";
    pub const struct_codec_v1: []const u8 = "struct-v1";

    pub const Frame = struct {
        type: u8,
        stream_id: u32,
        payload: []const u8,
    };

    pub const DecodeResult = union(enum) {
        frame: Frame,
        status: Status,
    };

    pub fn decodeFrame(data: []const u8) DecodeResult {
        if (data.len < header_len) {
            return .{ .status = Status.init(wire.codeInvalidArgument,
                "frame shorter than 9-byte header") };
        }
        const length = getU32(data, 5);
        if (length != data.len - header_len) {
            return .{ .status = Status.init(wire.codeInvalidArgument,
                "payload length does not match message size") };
        }
        return .{ .frame = .{
            .type = data[0],
            .stream_id = getU32(data, 1),
            .payload = data[header_len..],
        } };
    }

    pub const EncodeResult = union(enum) {
        bytes: []u8,
        status: Status,
    };

    /// Build one DataChannel message: header + payload.
    pub fn encodeFrame(alloc: std.mem.Allocator, frame_type: u8, stream_id: u32, payload: []const u8) EncodeResult {
        if (!wire.isFrameType(frame_type)) {
            return .{ .status = Status.init(wire.codeInvalidArgument, "unknown frame type") };
        }
        if (frame_type == wire.frameData and payload.len > max_data_payload) {
            return .{ .status = Status.init(wire.codeResourceExhausted, "DATA payload exceeds 16 MiB") };
        }
        const out = alloc.alloc(u8, header_len + payload.len) catch
            return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
        out[0] = frame_type;
        putU32(out, 1, stream_id);
        putU32(out, 5, @intCast(payload.len));
        @memcpy(out[header_len..], payload);
        return .{ .bytes = out };
    }

    pub fn putU32(out: []u8, offset: usize, value: u32) void {
        out[offset] = @intCast((value >> 24) & 0xff);
        out[offset + 1] = @intCast((value >> 16) & 0xff);
        out[offset + 2] = @intCast((value >> 8) & 0xff);
        out[offset + 3] = @intCast(value & 0xff);
    }

    pub fn getU32(input: []const u8, offset: usize) u32 {
        return (@as(u32, input[offset]) << 24) |
            (@as(u32, input[offset + 1]) << 16) |
            (@as(u32, input[offset + 2]) << 8) |
            @as(u32, input[offset + 3]);
    }

    pub const HeadersResult = union(enum) {
        headers: Headers,
        status: Status,
    };

    /// Parse a HEADERS payload. Keys/values are duplicated with alloc;
    /// free with freeHeaders. Metadata preserves insertion order via
    /// JSON object order (std.json.ObjectMap is insertion-ordered).
    pub fn parseHeaders(alloc: std.mem.Allocator, payload: []const u8) HeadersResult {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch
            return .{ .status = Status.init(wire.codeInvalidArgument, "bad HEADERS payload") };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return .{ .status = Status.init(wire.codeInvalidArgument, "bad HEADERS payload: not an object") };
        }
        var headers = Headers{ .metadata = std.StringHashMap([]const u8).init(alloc) };
        if (parsed.value.object.get("path")) |p| {
            if (p == .string) {
                headers.path = alloc.dupe(u8, p.string) catch
                    return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
            }
        }
        if (parsed.value.object.get("metadata")) |md| {
            if (md == .object) {
                var it = md.object.iterator();
                while (it.next()) |entry| {
                    const key = alloc.dupe(u8, entry.key_ptr.*) catch continue;
                    const val = switch (entry.value_ptr.*) {
                        .string => |s| alloc.dupe(u8, s) catch continue,
                        else => alloc.dupe(u8, "") catch continue,
                    };
                    headers.metadata.put(key, val) catch continue;
                }
            }
        }
        return .{ .headers = headers };
    }

    pub fn freeHeaders(alloc: std.mem.Allocator, headers: *Headers) void {
        if (headers.path) |p| alloc.free(p);
        var it = headers.metadata.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        headers.metadata.deinit();
    }

    pub fn headersFrame(alloc: std.mem.Allocator, stream_id: u32, path: ?[]const u8, metadata: ?*const std.StringHashMap([]const u8)) EncodeResult {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        aw.writer.writeAll("{") catch return oom();
        var wrote = false;
        if (path) |p| {
            aw.writer.writeAll("\"path\":") catch return oom();
            writeJsonString(&aw.writer, p) catch return oom();
            wrote = true;
        }
        if (metadata) |md| {
            if (md.count() > 0) {
                if (wrote) aw.writer.writeAll(",") catch return oom();
                aw.writer.writeAll("\"metadata\":{") catch return oom();
                var it = md.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) aw.writer.writeAll(",") catch return oom();
                    first = false;
                    writeJsonString(&aw.writer, entry.key_ptr.*) catch return oom();
                    aw.writer.writeAll(":") catch return oom();
                    writeJsonString(&aw.writer, entry.value_ptr.*) catch return oom();
                }
                aw.writer.writeAll("}") catch return oom();
            }
        }
        aw.writer.writeAll("}") catch return oom();
        return encodeFrame(alloc, wire.frameHeaders, stream_id, aw.written());
    }

    /// gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
    /// units H/M/S/m/u/n (at most 8 digits). Encoding uses
    /// milliseconds (seconds past the digit limit), rounded up.
    /// Caller owns the returned string.
    pub fn encodeTimeout(alloc: std.mem.Allocator, timeout_ms: u64) []u8 {
        if (timeout_ms <= 99999999) {
            return std.fmt.allocPrint(alloc, "{d}m", .{timeout_ms}) catch @panic("out of memory");
        }
        return std.fmt.allocPrint(alloc, "{d}S", .{(timeout_ms + 999) / 1000}) catch @panic("out of memory");
    }

    /// Decoded grpc-timeout in milliseconds, or null when malformed.
    pub fn parseTimeout(text: []const u8) ?u64 {
        if (text.len < 2 or text.len > 9) return null;
        var n: u64 = 0;
        for (text[0 .. text.len - 1]) |c| {
            if (c < '0' or c > '9') return null;
            n = n * 10 + (c - '0');
        }
        return switch (text[text.len - 1]) {
            'H' => n * 3600000,
            'M' => n * 60000,
            'S' => n * 1000,
            'm' => n,
            'u' => (n + 999) / 1000,
            'n' => (n + 999999) / 1000000,
            else => null,
        };
    }

    pub fn statusFrame(alloc: std.mem.Allocator, frame_type: u8, stream_id: u32, st: Status) EncodeResult {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        aw.writer.print("{{\"code\":{d},\"message\":", .{st.code}) catch return oom();
        writeJsonString(&aw.writer, st.message) catch return oom();
        if (st.trailers.len > 0) {
            aw.writer.writeAll(",\"metadata\":{") catch return oom();
            for (st.trailers, 0..) |pair, i| {
                if (i > 0) aw.writer.writeAll(",") catch return oom();
                writeJsonString(&aw.writer, pair.key) catch return oom();
                aw.writer.writeAll(":") catch return oom();
                writeJsonString(&aw.writer, pair.value) catch return oom();
            }
            aw.writer.writeAll("}") catch return oom();
        }
        aw.writer.writeAll("}") catch return oom();
        return encodeFrame(alloc, frame_type, stream_id, aw.written());
    }

    /// Parse a TRAILERS/RST payload; the message is duplicated with
    /// alloc (caller owns it). Malformed payloads yield UNKNOWN.
    pub fn parseStatus(alloc: std.mem.Allocator, payload: []const u8) Status {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch
            return Status.init(wire.codeUnknown, "malformed trailers");
        defer parsed.deinit();
        if (parsed.value != .object) return Status.init(wire.codeUnknown, "malformed trailers");
        const code_val = parsed.value.object.get("code") orelse
            return Status.init(wire.codeUnknown, "malformed trailers");
        if (code_val != .integer) return Status.init(wire.codeUnknown, "malformed trailers");
        var message: []const u8 = "";
        if (parsed.value.object.get("message")) |m| {
            if (m == .string) message = m.string;
        }
        const owned = alloc.dupe(u8, message) catch "";
        var status = Status.init(@intCast(code_val.integer), owned);
        if (parsed.value.object.get("metadata")) |md| {
            if (md == .object) {
                var pairs: std.ArrayList(status_mod.TrailerPair) = .empty;
                var it = md.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .string) continue;
                    const k = alloc.dupe(u8, entry.key_ptr.*) catch continue;
                    const v = alloc.dupe(u8, entry.value_ptr.*.string) catch continue;
                    pairs.append(alloc, .{ .key = k, .value = v }) catch continue;
                }
                status.trailers = pairs.toOwnedSlice(alloc) catch &.{};
            }
        }
        return status;
    }

    fn oom() EncodeResult {
        return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
    }
};

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    var stringify = std.json.Stringify{ .writer = w, .options = .{} };
    try stringify.write(s);
}
GRPC_RUNTIME_EOF
)

(define zig-transport-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");

/// Carries whole DataChannel messages: one send is one message,
/// boundaries preserved, ordered and reliable — the contract an
/// RTCDataChannel (or the loopback pair) offers. recv blocks until a
/// message arrives; null means the transport closed. Received slices
/// are allocated with the caller's allocator and owned by the caller.
pub const Transport = struct {
    ctx: *anyopaque,
    send_fn: *const fn (ctx: *anyopaque, data: []const u8) anyerror!void,
    recv_fn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8,
    close_fn: *const fn (ctx: *anyopaque) void,
    /// Optional non-blocking receive for single-threaded
    /// environments (wasm32): error.WouldBlock when no message
    /// is available right now, null when closed. When set, the
    /// endpoint runs inline — no read thread; stream waits
    /// pump the transport through this hook.
    try_recv_fn: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 = null,

    pub fn send(self: Transport, data: []const u8) !void {
        return self.send_fn(self.ctx, data);
    }

    pub fn recv(self: Transport, alloc: std.mem.Allocator) !?[]u8 {
        return self.recv_fn(self.ctx, alloc);
    }

    pub fn tryRecv(self: Transport, alloc: std.mem.Allocator) anyerror!?[]u8 {
        const f = self.try_recv_fn orelse return error.WouldBlock;
        return f(self.ctx, alloc);
    }

    pub fn close(self: Transport) void {
        self.close_fn(self.ctx);
    }
};

/// Message metadata carried in HEADERS.
pub const Metadata = std.StringHashMap([]const u8);
GRPC_RUNTIME_EOF
)

(define zig-endpoint-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const wire = @import("wire.zig");
const codec_mod = @import("codec.zig");
const status_mod = @import("status.zig");
const transport_mod = @import("transport.zig");

pub const Codec = codec_mod.Codec;
pub const Headers = codec_mod.Headers;

const builtin = @import("builtin");

/// Condition variable, or a no-op stand-in on single-threaded
/// targets (wasm32-freestanding has no futex/clock): there the
/// endpoint always runs inline — waits pump the transport
/// instead — so wait() is unreachable.
const Cond = if (builtin.single_threaded) struct {
    pub fn wait(_: *@This(), _: *std.Thread.Mutex) void {
        unreachable;
    }
    pub fn timedWait(_: *@This(), _: *std.Thread.Mutex, _: u64) error{Timeout}!void {
        unreachable;
    }
    pub fn signal(_: *@This()) void {}
    pub fn broadcast(_: *@This()) void {}
} else std.Thread.Condition;
pub const Status = status_mod.Status;
pub const Transport = transport_mod.Transport;
pub const Metadata = transport_mod.Metadata;

/// Stream event kinds delivered to StreamInput queues.
pub const EventKind = enum { headers, data, half_close, trailers, rst };

pub const StreamEvent = struct {
    kind: EventKind,
    headers: ?Headers = null,
    payload: ?[]u8 = null,
    status: ?Status = null,

    pub fn deinit(self: *StreamEvent, alloc: std.mem.Allocator) void {
        if (self.headers) |*h| Codec.freeHeaders(alloc, h);
        if (self.payload) |p| alloc.free(p);
        if (self.status) |s| {
            if (s.message.len > 0) alloc.free(s.message);
            for (s.trailers) |pair| {
                alloc.free(pair.key);
                alloc.free(pair.value);
            }
            if (s.trailers.len > 0) alloc.free(s.trailers);
        }
        self.* = undefined;
    }
};

/// Receiving queue of one stream; closed after a terminal event.
/// put transfers ownership of the event's allocations; get transfers
/// them to the caller (free with event.deinit).
/// Host clock hook for targets without a native monotonic clock
/// (wasm32-freestanding in a browser worker). Install before
/// opening calls; the hook returns monotonic milliseconds. This
/// is intentionally process-global because such targets are
/// single-threaded and one host page supplies one clock.
pub const NowMsFn = *const fn () i64;
var now_ms_hook: ?NowMsFn = null;

pub fn setNowMsHook(hook: ?NowMsFn) void {
    now_ms_hook = hook;
}

/// Monotonic milliseconds, or null when no clock is available.
/// Without a host hook on single-threaded targets, deadlines
/// still propagate but cannot be enforced locally.
pub fn nowMs() ?i64 {
    if (now_ms_hook) |hook| return hook();
    if (comptime builtin.single_threaded) {
        return null;
    }
    return std.time.milliTimestamp();
}

pub const GetResult = union(enum) {
    event: ?StreamEvent,
    timeout,
};

pub const StreamInput = struct {
    mutex: std.Thread.Mutex = .{},
    cond: Cond = .{},
    queue: std.ArrayList(StreamEvent) = .empty,
    closed: bool = false,
    /// Inline (single-threaded) mode: get() drives the
    /// endpoint through this hook instead of waiting.
    pump_ctx: ?*anyopaque = null,
    pump_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn put(self: *StreamInput, alloc: std.mem.Allocator, event: StreamEvent) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) {
            var ev = event;
            ev.deinit(alloc);
            return;
        }
        self.queue.append(alloc, event) catch {
            var ev = event;
            ev.deinit(alloc);
            return;
        };
        self.cond.signal();
    }

    pub fn close(self: *StreamInput) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }

    /// Next event, or null once the stream is closed and drained.
    pub fn get(self: *StreamInput) ?StreamEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len == 0) {
            if (self.closed) return null;
            if (self.pump_fn) |pf| {
                // Inline mode: pump the endpoint (which
                // delivers via put()) instead of waiting.
                self.mutex.unlock();
                pf(self.pump_ctx.?);
                self.mutex.lock();
                continue;
            }
            self.cond.wait(&self.mutex);
        }
        return self.queue.orderedRemove(0);
    }

    /// Timed get: .timeout when the deadline (nowMs clock) passes.
    pub fn getUntil(self: *StreamInput, deadline_ms: ?i64) GetResult {
        const deadline = deadline_ms orelse return .{ .event = self.get() };
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len == 0) {
            if (self.closed) return .{ .event = null };
            const now = nowMs() orelse deadline;
            if (now >= deadline) return .timeout;
            if (self.pump_fn) |pf| {
                self.mutex.unlock();
                pf(self.pump_ctx.?);
                self.mutex.lock();
                continue;
            }
            const remaining_ns: u64 = @intCast((deadline - now) * std.time.ns_per_ms);
            self.cond.timedWait(&self.mutex, remaining_ns) catch return .timeout;
        }
        return .{ .event = self.queue.orderedRemove(0) };
    }

    pub fn deinit(self: *StreamInput, alloc: std.mem.Allocator) void {
        for (self.queue.items) |*ev| ev.deinit(alloc);
        self.queue.deinit(alloc);
    }
};

/// Response initial/trailing metadata accumulated during one
/// call; shared between CallContext and ResponseSink.
pub const ResponseState = struct {
    headers: Metadata,
    trailers: Metadata,
    headers_sent: bool = false,
};

/// Per-call context: metadata sent in HEADERS.
pub const CallContext = struct {
    metadata: Metadata,
    /// Deadline (nowMs clock) propagated via grpc-timeout, if any.
    deadline_ms: ?i64 = null,
    /// This call's server span context (null when dormant).
    trace_context: ?status_mod.TraceContext = null,
    /// Whether this call negotiated the struct codec (HEADERS dc-codec: struct-v1).
    struct_codec: bool = false,
    /// Shared response-metadata state (endpoint-installed).
    response: ?*ResponseState = null,

    /// Marshal a response message with this call's negotiated codec (generated server code calls this).
    pub fn encodeMessage(self: *const CallContext, alloc: std.mem.Allocator, msg: anytype) []u8 {
        return codec_mod.marshalForCodec(alloc, self.struct_codec, msg);
    }

    /// Record response initial metadata (sent lazily, before
    /// the first response message).
    pub fn setHeaders(self: *CallContext, md: *const Metadata) void {
        const state = self.response orelse return;
        var it = md.iterator();
        while (it.next()) |entry| {
            state.headers.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    /// Record response trailing metadata (rides the terminal
    /// status frame).
    pub fn setTrailers(self: *CallContext, md: *const Metadata) void {
        const state = self.response orelse return;
        var it = md.iterator();
        while (it.next()) |entry| {
            state.trailers.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
    }

    /// Milliseconds left before the deadline, or null when unbounded.
    pub fn timeRemainingMs(self: *const CallContext) ?i64 {
        const deadline = self.deadline_ms orelse return null;
        const now = nowMs() orelse return null;
        return @max(0, deadline - now);
    }

    pub fn deadlineExceeded(self: *const CallContext) bool {
        const left = self.timeRemainingMs() orelse return false;
        return left == 0;
    }
};

/// Sends response payloads of one inbound call.
pub const ResponseSink = struct {
    endpoint: *Endpoint,
    stream_id: u32,
    /// Shared response-metadata state (endpoint-installed).
    state: ?*ResponseState = null,

    // Inline mode has no read thread: while a handler runs on
    // the pump stack, nothing else receives, so a peer RST sits
    // unread and the forgotten-stream check below never trips.
    // Pump one frame first so onTerminal can forget the stream.
    fn pumpIfInline(self: ResponseSink) void {
        if (self.endpoint.inline_pump) self.endpoint.pollOnce();
    }

    pub fn send(self: ResponseSink, payload: []const u8) Status {
        // A stream the endpoint has forgotten was RST by the peer
        // (or the channel went away): fail the send so a producing
        // handler stops instead of streaming into the void.
        self.pumpIfInline();
        if (self.endpoint.stream(self.stream_id) == null) {
            return Status.init(wire.codeCancelled, "call cancelled");
        }
        const hst = self.flushHeaders();
        if (!hst.isOk()) return hst;
        const frame = switch (Codec.encodeFrame(self.endpoint.alloc, wire.frameData, self.stream_id, payload)) {
            .bytes => |b| b,
            .status => |st| return st,
        };
        defer self.endpoint.alloc.free(frame);
        self.endpoint.sendFrame(frame);
        return Status.ok();
    }

    /// Send the initial-metadata HEADERS once (with whatever
    /// the handler recorded via CallContext.setHeaders).
    pub fn flushHeaders(self: ResponseSink) Status {
        const state = self.state orelse return Status.ok();
        if (state.headers_sent) return Status.ok();
        state.headers_sent = true;
        return self.sendHeadersMd(&state.headers);
    }

    pub fn sendHeaders(self: ResponseSink) Status {
        return self.flushHeaders();
    }

    fn sendHeadersMd(self: ResponseSink, md: *const Metadata) Status {
        self.pumpIfInline();
        if (self.endpoint.stream(self.stream_id) == null) {
            return Status.init(wire.codeCancelled, "call cancelled");
        }
        const frame = switch (Codec.headersFrame(self.endpoint.alloc, self.stream_id, null, md)) {
            .bytes => |b| b,
            .status => |st| return st,
        };
        defer self.endpoint.alloc.free(frame);
        self.endpoint.sendFrame(frame);
        return Status.ok();
    }

    pub fn sendTrailers(self: ResponseSink, st: Status) void {
        var merged = st;
        var pairs: std.ArrayList(status_mod.TrailerPair) = .empty;
        defer pairs.deinit(self.endpoint.alloc);
        if (st.trailers.len == 0) {
            if (self.state) |state| {
                var it = state.trailers.iterator();
                while (it.next()) |entry| {
                    pairs.append(self.endpoint.alloc, .{
                        .key = entry.key_ptr.*,
                        .value = entry.value_ptr.*,
                    }) catch {};
                }
                merged.trailers = pairs.items;
            }
        }
        const frame = switch (Codec.statusFrame(self.endpoint.alloc, wire.frameTrailers, self.stream_id, merged)) {
            .bytes => |b| b,
            .status => return,
        };
        defer self.endpoint.alloc.free(frame);
        self.endpoint.sendFrame(frame);
    }
};

/// Server-side call handler installed by Server. Returns the status
/// that becomes the call's TRAILERS (Status.ok() for success).
pub const Dispatcher = *const fn (
    ctx: *anyopaque,
    call_ctx: CallContext,
    headers: Headers,
    input: *StreamInput,
    sink: ResponseSink,
) Status;

/// Multiplexes grpc-dc streams over one Transport.
pub const Endpoint = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    dispatcher_ctx: ?*anyopaque = null,
    dispatcher: ?Dispatcher = null,
    next_id: u32,
    streams: std.AutoHashMap(u32, *StreamInput),
    streams_mutex: std.Thread.Mutex = .{},
    all_inputs: std.ArrayList(*StreamInput) = .empty,
    closed: bool = false,
    started: bool = false,
    inline_pump: bool = false,
    read_thread: if (builtin.single_threaded) u0 else ?std.Thread = if (builtin.single_threaded) 0 else null,
    active_calls: usize = 0,
    calls_mutex: std.Thread.Mutex = .{},
    calls_cond: Cond = .{},

    /// The side that created the channel allocates odd stream ids, the
    /// answerer even. The read loop starts on start() — after any
    /// dispatcher is installed, so an early HEADERS can never race
    /// dispatcher setup.
    pub fn init(alloc: std.mem.Allocator, transport: Transport, creator: bool) Endpoint {
        return .{
            .alloc = alloc,
            .transport = transport,
            .next_id = if (creator) 1 else 2,
            .streams = std.AutoHashMap(u32, *StreamInput).init(alloc),
        };
    }

    /// Start the read loop (idempotent). A transport with
    /// try_recv runs inline instead: no thread is spawned and
    /// stream waits pump the transport (single-threaded
    /// environments such as wasm32).
    pub fn start(self: *Endpoint) void {
        if (self.started) return;
        self.started = true;
        if (self.transport.try_recv_fn != null) {
            self.inline_pump = true;
            return;
        }
        if (comptime builtin.single_threaded) {
            self.inline_pump = true;
            return;
        }
        self.read_thread = std.Thread.spawn(.{}, readLoop, .{self}) catch null;
    }

    /// Inline mode: receive and dispatch at most one message.
    pub fn pollOnce(self: *Endpoint) void {
        const msg = self.transport.tryRecv(self.alloc) catch return;
        const data = msg orelse {
            self.failAll();
            return;
        };
        self.onBytes(data);
        self.alloc.free(data);
    }

    fn pumpThunk(ctx: *anyopaque) void {
        const self: *Endpoint = @ptrCast(@alignCast(ctx));
        self.pollOnce();
    }

    fn attachPump(self: *Endpoint, input: *StreamInput) void {
        if (self.inline_pump) {
            input.pump_ctx = self;
            input.pump_fn = &pumpThunk;
        }
    }

    pub fn deinit(self: *Endpoint) void {
        self.close();
        if (comptime !builtin.single_threaded) {
            if (self.read_thread) |t| t.join();
        }
        self.waitIdle();
        for (self.all_inputs.items) |input| {
            input.deinit(self.alloc);
            self.alloc.destroy(input);
        }
        self.all_inputs.deinit(self.alloc);
        self.streams.deinit();
    }

    pub fn close(self: *Endpoint) void {
        if (self.closed) return;
        self.closed = true;
        self.transport.close();
        self.failAll();
    }

    fn waitIdle(self: *Endpoint) void {
        if (self.inline_pump) {
            while (true) {
                self.calls_mutex.lock();
                const idle = self.active_calls == 0;
                self.calls_mutex.unlock();
                if (idle) return;
                self.pollOnce();
            }
        }
        self.calls_mutex.lock();
        defer self.calls_mutex.unlock();
        while (self.active_calls > 0) {
            self.calls_cond.wait(&self.calls_mutex);
        }
    }

    pub fn sendFrame(self: *Endpoint, frame: []const u8) void {
        self.transport.send(frame) catch {};
    }

    pub const Opened = struct { id: u32, input: *StreamInput };

    pub fn openStream(self: *Endpoint) Opened {
        const input = self.alloc.create(StreamInput) catch @panic("out of memory");
        input.* = .{};
        self.attachPump(input);
        self.streams_mutex.lock();
        defer self.streams_mutex.unlock();
        const id = self.next_id;
        self.next_id += 2;
        self.streams.put(id, input) catch {};
        self.all_inputs.append(self.alloc, input) catch {};
        return .{ .id = id, .input = input };
    }

    pub fn closeStream(self: *Endpoint, id: u32) void {
        self.streams_mutex.lock();
        defer self.streams_mutex.unlock();
        _ = self.streams.remove(id);
    }

    /// Abort one stream: RST out; a pending get wakes with CANCELLED.
    pub fn cancelStream(self: *Endpoint, id: u32) void {
        self.streams_mutex.lock();
        const input = self.streams.fetchRemove(id);
        self.streams_mutex.unlock();
        if (input) |kv| {
            const msg = self.alloc.dupe(u8, "call cancelled") catch "";
            kv.value.put(self.alloc, .{ .kind = .rst, .status = Status.init(wire.codeCancelled, msg) });
            kv.value.close();
        }
        const frame = switch (Codec.statusFrame(self.alloc, wire.frameRst, id, Status.init(wire.codeCancelled, "call cancelled"))) {
            .bytes => |b| b,
            .status => return,
        };
        defer self.alloc.free(frame);
        self.sendFrame(frame);
    }

    fn stream(self: *Endpoint, id: u32) ?*StreamInput {
        self.streams_mutex.lock();
        defer self.streams_mutex.unlock();
        return self.streams.get(id);
    }

    fn registerStream(self: *Endpoint, id: u32, input: *StreamInput) void {
        self.attachPump(input);
        self.streams_mutex.lock();
        defer self.streams_mutex.unlock();
        self.streams.put(id, input) catch {};
        self.all_inputs.append(self.alloc, input) catch {};
    }

    fn failAll(self: *Endpoint) void {
        self.streams_mutex.lock();
        var inputs: std.ArrayList(*StreamInput) = .empty;
        var it = self.streams.valueIterator();
        while (it.next()) |v| inputs.append(self.alloc, v.*) catch {};
        self.streams.clearRetainingCapacity();
        self.streams_mutex.unlock();
        for (inputs.items) |input| {
            const msg = self.alloc.dupe(u8, "data channel closed") catch "";
            input.put(self.alloc, .{ .kind = .rst, .status = Status.init(wire.codeUnavailable, msg) });
            input.close();
        }
        inputs.deinit(self.alloc);
    }

    fn readLoop(self: *Endpoint) void {
        while (true) {
            const msg = self.transport.recv(self.alloc) catch break;
            const data = msg orelse break;
            self.onBytes(data);
            self.alloc.free(data);
            if (self.closed) break;
        }
        self.failAll();
    }

    fn onBytes(self: *Endpoint, data: []const u8) void {
        if (self.closed) return;
        const frame = switch (Codec.decodeFrame(data)) {
            .frame => |f| f,
            .status => return, // malformed frame: drop, keep the channel up
        };
        @@FRAME_DISPATCH@@
    }

    fn onTerminal(self: *Endpoint, stream_id: u32, payload: []const u8, kind: EventKind) void {
        if (self.stream(stream_id)) |input| {
            const st = Codec.parseStatus(self.alloc, payload);
            input.put(self.alloc, .{ .kind = kind, .status = st });
            input.close();
            self.closeStream(stream_id);
        }
    }

    fn onHeaders(self: *Endpoint, stream_id: u32, payload: []const u8) void {
        var headers = switch (Codec.parseHeaders(self.alloc, payload)) {
            .headers => |h| h,
            .status => |st| {
                self.sendStatusFrame(wire.frameRst, stream_id, st);
                return;
            },
        };
        if (headers.path == null) {
            // Server response headers for one of our outbound streams.
            if (self.stream(stream_id)) |input| {
                input.put(self.alloc, .{ .kind = .headers, .headers = headers });
            } else {
                Codec.freeHeaders(self.alloc, &headers);
            }
            return;
        }
        if (self.stream(stream_id) != null) {
            Codec.freeHeaders(self.alloc, &headers);
            self.sendStatusFrame(wire.frameRst, stream_id,
                Status.init(wire.codeInternal, "HEADERS for stream already in use"));
            return;
        }
        const dispatcher = self.dispatcher orelse {
            const msg = std.fmt.allocPrint(self.alloc, "unknown method {s}", .{headers.path.?}) catch "unknown method";
            self.sendStatusFrame(wire.frameTrailers, stream_id, Status.init(wire.codeUnimplemented, msg));
            if (msg.len > 0) self.alloc.free(msg);
            Codec.freeHeaders(self.alloc, &headers);
            return;
        };
        const input = self.alloc.create(StreamInput) catch {
            Codec.freeHeaders(self.alloc, &headers);
            return;
        };
        input.* = .{};
        self.registerStream(stream_id, input);
        self.calls_mutex.lock();
        self.active_calls += 1;
        self.calls_mutex.unlock();
        const args = self.alloc.create(DispatchArgs) catch {
            self.endCall();
            Codec.freeHeaders(self.alloc, &headers);
            return;
        };
        args.* = .{
            .endpoint = self,
            .ctx = self.dispatcher_ctx.?,
            .dispatcher = dispatcher,
            .headers = headers,
            .input = input,
            .stream_id = stream_id,
        };
        if (self.inline_pump) {
            dispatchMain(args);
            return;
        }
        if (comptime builtin.single_threaded) {
            dispatchMain(args);
            return;
        }
        const thread = std.Thread.spawn(.{}, dispatchMain, .{args}) catch {
            self.alloc.destroy(args);
            self.endCall();
            return;
        };
        thread.detach();
    }

    const DispatchArgs = struct {
        endpoint: *Endpoint,
        ctx: *anyopaque,
        dispatcher: Dispatcher,
        headers: Headers,
        input: *StreamInput,
        stream_id: u32,
    };

    fn dispatchMain(args: *DispatchArgs) void {
        const self = args.endpoint;
        defer {
            self.closeStream(args.stream_id);
            self.endCall();
            self.alloc.destroy(args);
        }
        var headers = args.headers;
        defer Codec.freeHeaders(self.alloc, &headers);
        // No eager HEADERS: initial metadata flushes lazily via
        // the sink (first DATA, or below on a DATA-less success)
        // so handlers can setHeaders first. Errors end
        // trailers-only, as gRPC allows.
        var response_state = ResponseState{
            .headers = Metadata.init(self.alloc),
            .trailers = Metadata.init(self.alloc),
        };
        defer response_state.headers.deinit();
        defer response_state.trailers.deinit();
        const sink = ResponseSink{ .endpoint = self, .stream_id = args.stream_id, .state = &response_state };
        var call_ctx = CallContext{ .metadata = headers.metadata, .response = &response_state };
        if (headers.metadata.get("grpc-timeout")) |text| {
            if (Codec.parseTimeout(text)) |ms| {
                if (nowMs()) |now| {
                    call_ctx.deadline_ms = now + @as(i64, @intCast(ms));
                }
            }
        }
        const st = args.dispatcher(args.ctx, call_ctx, headers, args.input, sink);
        if (st.isOk()) _ = sink.flushHeaders();
        sink.sendTrailers(st);
    }

    fn endCall(self: *Endpoint) void {
        self.calls_mutex.lock();
        defer self.calls_mutex.unlock();
        if (self.active_calls > 0) self.active_calls -= 1;
        self.calls_cond.broadcast();
    }

    fn sendStatusFrame(self: *Endpoint, frame_type: u8, stream_id: u32, st: Status) void {
        const frame = switch (Codec.statusFrame(self.alloc, frame_type, stream_id, st)) {
            .bytes => |b| b,
            .status => return,
        };
        defer self.alloc.free(frame);
        self.sendFrame(frame);
    }
};
GRPC_RUNTIME_EOF
)

(define zig-channel-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const wire = @import("wire.zig");
const codec_mod = @import("codec.zig");
const endpoint_mod = @import("endpoint.zig");
const status_mod = @import("status.zig");
const transport_mod = @import("transport.zig");

pub const Codec = codec_mod.Codec;
pub const Headers = codec_mod.Headers;
pub const Endpoint = endpoint_mod.Endpoint;
pub const StreamEvent = endpoint_mod.StreamEvent;
pub const Status = status_mod.Status;
pub const RecvOutcome = status_mod.RecvOutcome;
pub const Metadata = transport_mod.Metadata;

/// Receives response messages of one call.
pub const ClientStream = struct {
    stream_id: u32,
    input: *endpoint_mod.StreamInput,
    endpoint: *Endpoint,
    headers: ?Headers = null,
    /// Trailing metadata of the terminal status (valid until deinit).
    trailers: []const status_mod.TrailerPair = &.{},
    deadline_ms: ?i64 = null,
    trace_ctx: ?status_mod.TraceContext = null,
    trace_path: []const u8 = "",
    trace_ended: bool = false,
    terminated: bool = false,
    struct_codec: bool = false,

    pub fn endTrace(self: *ClientStream, status: []const u8) void {
        if (!self.trace_ended) {
            self.trace_ended = true;
            status_mod.traceEnd("client", self.trace_path, self.trace_ctx, status);
        }
    }

    /// Send one request message on an open stream (no half-close).
    pub fn send(self: *ClientStream, msg: anytype) Status {
        const alloc = self.endpoint.alloc;
        const payload = codec_mod.marshalForCodec(alloc, self.struct_codec, msg);
        defer alloc.free(payload);
        const frame = switch (Codec.encodeFrame(alloc, wire.frameData, self.stream_id, payload)) {
            .bytes => |b| b,
            .status => |st| return st,
        };
        defer alloc.free(frame);
        self.endpoint.sendFrame(frame);
        return Status.ok();
    }

    /// Half-close an open stream (no more requests).
    pub fn halfClose(self: *ClientStream) void {
        const alloc = self.endpoint.alloc;
        const frame = switch (Codec.encodeFrame(alloc, wire.frameHalfClose, self.stream_id, "")) {
            .bytes => |b| b,
            .status => return,
        };
        defer alloc.free(frame);
        self.endpoint.sendFrame(frame);
    }

    /// Abort this stream (sends RST, wakes a pending recv).
    pub fn cancel(self: *ClientStream) void {
        self.endpoint.cancelStream(self.stream_id);
        self.terminated = true;
    }

    /// Receive the next response payload. End means the call
    /// completed OK; status reports the trailers status.
    pub fn recvRaw(self: *ClientStream) status_mod.RecvResult([]u8) {
        const alloc = self.endpoint.alloc;
        while (true) {
            var event = switch (self.input.getUntil(self.deadline_ms)) {
                .timeout => {
                    self.endpoint.cancelStream(self.stream_id);
                    self.terminated = true;
                    return .{ .status = Status.init(wire.codeDeadlineExceeded, "deadline exceeded") };
                },
                .event => |ev| ev orelse
                    return .{ .status = Status.init(wire.codeUnavailable, "data channel closed") },
            };
            switch (event.kind) {
                .headers => {
                    if (self.headers) |*h| Codec.freeHeaders(alloc, h);
                    self.headers = event.headers;
                    event.headers = null;
                    event.deinit(alloc);
                },
                .data => {
                    const payload = event.payload.?;
                    event.payload = null;
                    event.deinit(alloc);
                    return .{ .message = payload };
                },
                .trailers => {
                    self.terminated = true;
                    const st = event.status orelse Status.ok();
                    self.trailers = st.trailers;
                    event.status = null;
                    event.deinit(alloc);
                    // statusName returns a literal for known codes
                    // (the CODE_N fallback allocation is leaked by
                    // design of that helper; traced names are known).
                    self.endTrace(wire.statusName(alloc, st.code));
                    if (st.isOk()) return .end;
                    return .{ .status = st };
                },
                .rst => {
                    self.terminated = true;
                    const st = event.status orelse Status.init(wire.codeUnavailable, "stream reset");
                    self.trailers = st.trailers;
                    event.status = null;
                    event.deinit(alloc);
                    // statusName returns a literal for known codes
                    // (the CODE_N fallback allocation is leaked by
                    // design of that helper; traced names are known).
                    self.endTrace(wire.statusName(alloc, st.code));
                    return .{ .status = st };
                },
                .half_close => {
                    event.deinit(alloc);
                },
            }
        }
    }

    /// Decode the next response into resp (which must provide
    /// unmarshalDc([]const u8)).
    pub fn recvInto(self: *ClientStream, resp: anytype) RecvOutcome {
        switch (self.recvRaw()) {
            .message => |payload| {
                defer self.endpoint.alloc.free(payload);
                codec_mod.unmarshalForCodec(self.struct_codec, self.endpoint.alloc, payload, resp);
                return .message;
            },
            .end => return .end,
            .status => |st| return .{ .status = st },
        }
    }

    pub fn deinit(self: *ClientStream) void {
        if (!self.terminated) {
            // Abandoning a call that never terminated: RST
            // CANCELLED so the peer stops producing.
            self.endpoint.cancelStream(self.stream_id);
            self.terminated = true;
        }
        if (self.headers) |*h| Codec.freeHeaders(self.endpoint.alloc, h);
        const alloc = self.endpoint.alloc;
        for (self.trailers) |pair| {
            alloc.free(pair.key);
            alloc.free(pair.value);
        }
        if (self.trailers.len > 0) alloc.free(self.trailers);
        self.endpoint.closeStream(self.stream_id);
    }
};

pub const StreamResult = status_mod.CallResult(ClientStream);

/// Channel: the client side of one Endpoint.
pub const Channel = struct {
    endpoint: *Endpoint,
    owns_endpoint: bool,
    trace_context: ?status_mod.TraceContext = null,
    struct_codec: bool = false,

    /// Make every call on this channel request the struct codec
    /// (HEADERS marker dc-codec: struct-v1) and encode requests /
    /// decode responses with it. The server must enable it too
    /// (see Server.setStructCodec); otherwise calls fail
    /// Unimplemented. Mirrors the Go Channel.SetStructCodec.
    pub fn setStructCodec(self: *Channel, enabled: bool) void {
        self.struct_codec = enabled;
    }

    /// Parent this channel's outbound spans to ctx (usually
    /// CallContext.trace_context of the call being served, or a
    /// root from newTraceContext). Explicit metadata still wins.
    pub fn setTraceContext(self: *Channel, ctx: ?status_mod.TraceContext) void {
        self.trace_context = ctx;
    }

    /// Wrap a transport, allocating odd stream ids. The endpoint is
    /// allocated with alloc and freed by deinit.
    pub fn init(alloc: std.mem.Allocator, transport: transport_mod.Transport) Channel {
        const endpoint = alloc.create(Endpoint) catch @panic("out of memory");
        endpoint.* = Endpoint.init(alloc, transport, true);
        endpoint.start();
        return .{ .endpoint = endpoint, .owns_endpoint = true };
    }

    /// Wrap an existing endpoint (bidirectional use; starts its read loop).
    pub fn fromEndpoint(endpoint: *Endpoint) Channel {
        endpoint.start();
        return .{ .endpoint = endpoint, .owns_endpoint = false };
    }

    pub fn deinit(self: *Channel) void {
        if (self.owns_endpoint) {
            const alloc = self.endpoint.alloc;
            self.endpoint.deinit();
            alloc.destroy(self.endpoint);
        }
    }

    fn open(self: *Channel, path: []const u8, metadata: ?*const Metadata, timeout_ms: ?u64) StreamResult {
        const alloc = self.endpoint.alloc;
        var deadline_ms: ?i64 = null;
        var merged: ?Metadata = null;
        var timeout_text: ?[]u8 = null;
        defer if (timeout_text) |t| alloc.free(t);
        defer if (merged) |*m| m.deinit();
        var md = metadata;
        var trace_ctx: ?status_mod.TraceContext = null;
        var tp_buf: [55]u8 = undefined;
        if (timeout_ms != null or status_mod.tracingEnabled() or self.struct_codec) {
            merged = Metadata.init(alloc);
            if (metadata) |source| {
                var it = source.iterator();
                while (it.next()) |entry| {
                    merged.?.put(entry.key_ptr.*, entry.value_ptr.*) catch @panic("out of memory");
                }
            }
            if (self.struct_codec) {
                merged.?.put(Codec.struct_codec_header, Codec.struct_codec_v1) catch @panic("out of memory");
            }
            if (timeout_ms) |ms| {
                if (endpoint_mod.nowMs()) |now| {
                    deadline_ms = now + @as(i64, @intCast(ms));
                }
                timeout_text = Codec.encodeTimeout(alloc, ms);
                merged.?.put("grpc-timeout", timeout_text.?) catch @panic("out of memory");
            }
            if (status_mod.tracingEnabled()) {
                var parent = status_mod.parseTraceparent(if (metadata) |m| m.get("traceparent") else null);
                if (parent == null) {
                    if (self.trace_context) |*tc| parent = status_mod.parentOf(tc);
                }
                trace_ctx = status_mod.traceStart("client", path, parent);
                if (trace_ctx) |tc| {
                    merged.?.put("traceparent", status_mod.formatTraceparent(&tp_buf, &tc.trace_id, &tc.span_id, tc.sampled)) catch @panic("out of memory");
                }
            }
            md = &merged.?;
        }
        const opened = self.endpoint.openStream();
        const frame = switch (Codec.headersFrame(alloc, opened.id, path, md)) {
            .bytes => |b| b,
            .status => |st| {
                self.endpoint.closeStream(opened.id);
                status_mod.traceEnd("client", path, trace_ctx, "UNAVAILABLE");
                return .{ .status = st };
            },
        };
        defer alloc.free(frame);
        self.endpoint.sendFrame(frame);
        return .{ .ok = .{ .stream_id = opened.id, .input = opened.input, .endpoint = self.endpoint, .deadline_ms = deadline_ms, .trace_ctx = trace_ctx, .trace_path = path, .struct_codec = self.struct_codec } };
    }

    fn sendMessage(self: *Channel, stream: *ClientStream, payload: []const u8) Status {
        const alloc = self.endpoint.alloc;
        const frame = switch (Codec.encodeFrame(alloc, wire.frameData, stream.stream_id, payload)) {
            .bytes => |b| b,
            .status => |st| return st,
        };
        defer alloc.free(frame);
        self.endpoint.sendFrame(frame);
        return Status.ok();
    }

    fn halfClose(self: *Channel, stream: *ClientStream) void {
        const alloc = self.endpoint.alloc;
        const frame = switch (Codec.encodeFrame(alloc, wire.frameHalfClose, stream.stream_id, "")) {
            .bytes => |b| b,
            .status => return,
        };
        defer alloc.free(frame);
        self.endpoint.sendFrame(frame);
    }

    fn sendAll(self: *Channel, stream: *ClientStream, reqs: anytype) Status {
        const alloc = self.endpoint.alloc;
        for (reqs) |*req| {
            const payload = codec_mod.marshalForCodec(alloc, stream.struct_codec, req);
            defer alloc.free(payload);
            const st = self.sendMessage(stream, payload);
            if (!st.isOk()) return st;
        }
        self.halfClose(stream);
        return Status.ok();
    }

    fn collectOne(_: *Channel, stream: *ClientStream, resp: anytype, what: []const u8) Status {
        var got = false;
        while (true) {
            switch (stream.recvInto(resp)) {
                .message => {
                    if (got) {
                        return Status.init(wire.codeInternal,
                            if (std.mem.eql(u8, what, "unary")) "unary call received more than one response" else "client-streaming call received more than one response");
                    }
                    got = true;
                },
                .end => {
                    if (!got) return Status.init(wire.codeInternal, "call closed with no response");
                    return Status.ok();
                },
                .status => |st| return st,
            }
        }
    }

    /// Run a unary call, decoding the single response into resp.
    pub fn unary(self: *Channel, path: []const u8, req: anytype, resp: anytype, metadata: ?*const Metadata, timeout_ms: ?u64) Status {
        var stream = switch (self.open(path, metadata, timeout_ms)) {
            .ok => |s| s,
            .status => |st| return st,
        };
        defer stream.deinit();
        const alloc = self.endpoint.alloc;
        const payload = codec_mod.marshalForCodec(alloc, stream.struct_codec, req);
        defer alloc.free(payload);
        const st = self.sendMessage(&stream, payload);
        if (!st.isOk()) return st;
        self.halfClose(&stream);
        return self.collectOne(&stream, resp, "unary");
    }

    /// Start a server-streaming call.
    pub fn serverStream(self: *Channel, path: []const u8, req: anytype, metadata: ?*const Metadata, timeout_ms: ?u64) StreamResult {
        var stream = switch (self.open(path, metadata, timeout_ms)) {
            .ok => |s| s,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.endpoint.alloc;
        const payload = codec_mod.marshalForCodec(alloc, stream.struct_codec, req);
        defer alloc.free(payload);
        const st = self.sendMessage(&stream, payload);
        if (!st.isOk()) {
            stream.deinit();
            return .{ .status = st };
        }
        self.halfClose(&stream);
        return .{ .ok = stream };
    }

    /// Send all requests, then decode the one response into resp.
    pub fn clientStreamCall(self: *Channel, path: []const u8, reqs: anytype, resp: anytype, metadata: ?*const Metadata, timeout_ms: ?u64) Status {
        var stream = switch (self.open(path, metadata, timeout_ms)) {
            .ok => |s| s,
            .status => |st| return st,
        };
        defer stream.deinit();
        const st = self.sendAll(&stream, reqs);
        if (!st.isOk()) return st;
        return self.collectOne(&stream, resp, "client-streaming");
    }

    /// Open a stream without sending anything: drive it with
    /// ClientStream.send / halfClose / recvInto / cancel.
    pub fn openStream(self: *Channel, path: []const u8, metadata: ?*const Metadata, timeout_ms: ?u64) StreamResult {
        return self.open(path, metadata, timeout_ms);
    }

    /// Start a bidi call with all requests sent up front.
    pub fn bidi(self: *Channel, path: []const u8, reqs: anytype, metadata: ?*const Metadata, timeout_ms: ?u64) StreamResult {
        var stream = switch (self.open(path, metadata, timeout_ms)) {
            .ok => |s| s,
            .status => |st| return .{ .status = st },
        };
        const st = self.sendAll(&stream, reqs);
        if (!st.isOk()) {
            stream.deinit();
            return .{ .status = st };
        }
        return .{ .ok = stream };
    }
};
GRPC_RUNTIME_EOF
)

(define zig-server-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const wire = @import("wire.zig");
const codec_mod = @import("codec.zig");
const endpoint_mod = @import("endpoint.zig");
const status_mod = @import("status.zig");
const transport_mod = @import("transport.zig");

pub const Endpoint = endpoint_mod.Endpoint;
pub const CallContext = endpoint_mod.CallContext;
pub const ResponseSink = endpoint_mod.ResponseSink;
pub const Status = status_mod.Status;
pub const RecvOutcome = status_mod.RecvOutcome;
pub const Metadata = transport_mod.Metadata;

/// Reads request messages of one inbound call.
pub const RequestStream = struct {
    input: *endpoint_mod.StreamInput,
    alloc: std.mem.Allocator,
    struct_codec: bool = false,

    /// Next request payload; end at half-close.
    pub fn recvRaw(self: *RequestStream) status_mod.RecvResult([]u8) {
        while (true) {
            var event = self.input.get() orelse
                return .{ .status = Status.init(wire.codeUnavailable, "data channel closed") };
            switch (event.kind) {
                .data => {
                    const payload = event.payload.?;
                    event.payload = null;
                    event.deinit(self.alloc);
                    return .{ .message = payload };
                },
                .half_close => {
                    event.deinit(self.alloc);
                    return .end;
                },
                .trailers, .rst => {
                    const st = event.status orelse Status.init(wire.codeUnavailable, "stream closed");
                    event.status = null;
                    event.deinit(self.alloc);
                    return .{ .status = st };
                },
                .headers => {
                    event.deinit(self.alloc); // ignore HEADERS on the request side
                },
            }
        }
    }

    /// Decode the next request message into req.
    pub fn recvInto(self: *RequestStream, req: anytype) RecvOutcome {
        switch (self.recvRaw()) {
            .message => |payload| {
                defer self.alloc.free(payload);
                codec_mod.unmarshalForCodec(self.struct_codec, self.alloc, payload, req);
                return .message;
            },
            .end => return .end,
            .status => |st| return .{ .status = st },
        }
    }
};

/// Sends response payloads of one inbound call.
pub const Sink = struct {
    sink: ResponseSink,

    pub fn send(self: Sink, payload: []const u8) Status {
        return self.sink.send(payload);
    }
};

/// Implements one method against raw payloads; stubs adapt it.
pub const MethodHandler = *const fn (
    ctx: *anyopaque,
    call_ctx: *CallContext,
    reqs: *RequestStream,
    sink: Sink,
) Status;

pub const MethodKind = enum { unary, server_streaming, client_streaming, bidi };

/// One entry of a ServiceDesc.
pub const Method = struct {
    name: []const u8,
    path: []const u8,
    kind: MethodKind,
    ctx: *anyopaque,
    handler: MethodHandler,
};

/// Describes a service for Server.registerService.
pub const ServiceDesc = struct {
    name: []const u8,
    methods: []const Method,
};

/// Server: dispatches inbound calls to registered methods.
pub const Server = struct {
    alloc: std.mem.Allocator,
    methods: std.StringHashMap(Method),
    endpoint: ?*Endpoint = null,
    owns_endpoint: bool = false,
    struct_codec: bool = false,

    /// Enable the struct codec on this server: a call carrying
    /// HEADERS dc-codec: struct-v1 is decoded with the struct codec
    /// and answered in kind. A struct-v1 request to a server without
    /// it enabled fails Unimplemented, as does any other dc-codec
    /// value. Mirrors the Go Server.SetStructCodec.
    pub fn setStructCodec(self: *Server, enabled: bool) void {
        self.struct_codec = enabled;
    }

    pub fn init(alloc: std.mem.Allocator) Server {
        return .{ .alloc = alloc, .methods = std.StringHashMap(Method).init(alloc) };
    }

    pub fn deinit(self: *Server) void {
        if (self.owns_endpoint) {
            if (self.endpoint) |ep| {
                ep.deinit();
                self.alloc.destroy(ep);
            }
        }
        self.methods.deinit();
    }

    /// Adds a service's methods (generated code calls it).
    pub fn registerService(self: *Server, desc: ServiceDesc) void {
        for (desc.methods) |method| {
            self.methods.put(method.path, method) catch {};
        }
    }

    /// Attach to a transport (even stream ids); returns the Endpoint.
    pub fn serveTransport(self: *Server, transport: transport_mod.Transport) *Endpoint {
        const endpoint = self.alloc.create(Endpoint) catch @panic("out of memory");
        endpoint.* = Endpoint.init(self.alloc, transport, false);
        self.owns_endpoint = true;
        self.serveEndpoint(endpoint);
        return endpoint;
    }

    /// Attach to an existing endpoint (starts its read loop).
    pub fn serveEndpoint(self: *Server, endpoint: *Endpoint) void {
        self.endpoint = endpoint;
        endpoint.dispatcher_ctx = self;
        endpoint.dispatcher = dispatchEntry;
        endpoint.start();
    }

    fn dispatchEntry(ctx: *anyopaque, call_ctx: endpoint_mod.CallContext, headers: endpoint_mod.Headers, input: *endpoint_mod.StreamInput, sink: ResponseSink) Status {
        const self: *Server = @ptrCast(@alignCast(ctx));
        var mutable_ctx = call_ctx;
        const method = self.methods.get(headers.path.?) orelse {
            const msg = std.fmt.allocPrint(self.alloc, "unknown method {s}", .{headers.path.?}) catch
                return Status.init(wire.codeUnimplemented, "unknown method");
            defer self.alloc.free(msg);
            return Status.init(wire.codeUnimplemented, msg);
        };
        // Struct codec negotiation: an explicit dc-codec marker
        // must be struct-v1 and enabled here, else Unimplemented.
        var use_struct = false;
        if (headers.metadata.get(codec_mod.Codec.struct_codec_header)) |marker| {
            if (!std.mem.eql(u8, marker, codec_mod.Codec.struct_codec_v1) or !self.struct_codec) {
                return Status.init(wire.codeUnimplemented, "struct codec not enabled");
            }
            use_struct = true;
        }
        mutable_ctx.struct_codec = use_struct;
        const trace_ctx = status_mod.traceStart("server", headers.path.?, status_mod.parseTraceparent(headers.metadata.get("traceparent")));
        mutable_ctx.trace_context = trace_ctx;
        var reqs = RequestStream{ .input = input, .alloc = self.alloc, .struct_codec = use_struct };
        const result = method.handler(method.ctx, &mutable_ctx, &reqs, .{ .sink = sink });
        status_mod.traceEnd("server", headers.path.?, trace_ctx, wire.statusName(self.alloc, result.code));
        return result;
    }
};
GRPC_RUNTIME_EOF
)

(define zig-memory-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const transport_mod = @import("transport.zig");

const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    items: std.ArrayList([]u8) = .empty,
    closed: bool = false,
};

const Pair = struct {
    a_to_b: Queue = .{},
    b_to_a: Queue = .{},
};

const End = struct {
    pair: *Pair,
    inbox: *Queue,
    outbox: *Queue,
    closed: bool = false,
    alloc_ref: std.mem.Allocator = undefined,

    fn send(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *End = @ptrCast(@alignCast(ctx));
        self.outbox.mutex.lock();
        defer self.outbox.mutex.unlock();
        if (self.closed or self.outbox.closed) return error.Closed;
        // The queue shares the endpoint allocator lifetime in tests;
        // copies are made with the pair allocator below.
        const copy = try self.alloc_ref.dupe(u8, data);
        try self.outbox.items.append(self.alloc_ref, copy);
        self.outbox.cond.signal();
    }

    fn recv(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 {
        const self: *End = @ptrCast(@alignCast(ctx));
        self.inbox.mutex.lock();
        defer self.inbox.mutex.unlock();
        while (self.inbox.items.items.len == 0) {
            if (self.inbox.closed or self.closed) return null;
            self.inbox.cond.wait(&self.inbox.mutex);
        }
        _ = alloc; // messages were copied with the pair allocator
        return self.inbox.items.orderedRemove(0);
    }

    fn close(ctx: *anyopaque) void {
        const self: *End = @ptrCast(@alignCast(ctx));
        self.closed = true;
        self.inbox.mutex.lock();
        self.inbox.closed = true;
        self.inbox.cond.broadcast();
        self.inbox.mutex.unlock();
        self.outbox.mutex.lock();
        self.outbox.cond.broadcast();
        self.outbox.mutex.unlock();
    }

};

/// In-memory transport pair for tests (one queue per direction).
/// Messages are copied with alloc; received slices belong to the
/// receiver and must be freed with the same allocator passed to
/// Endpoint/transport recv (the endpoints use one allocator).
pub const MemoryPair = struct {
    pair: *Pair,
    end_a: *End,
    end_b: *End,

    pub fn deinit(self: *MemoryPair, alloc: std.mem.Allocator) void {
        for (self.pair.a_to_b.items.items) |item| alloc.free(item);
        for (self.pair.b_to_a.items.items) |item| alloc.free(item);
        self.pair.a_to_b.items.deinit(alloc);
        self.pair.b_to_a.items.deinit(alloc);
        alloc.destroy(self.pair);
        alloc.destroy(self.end_a);
        alloc.destroy(self.end_b);
    }
};

pub fn memoryTransportPair(alloc: std.mem.Allocator) MemoryPair {
    const pair = alloc.create(Pair) catch @panic("out of memory");
    pair.* = .{};
    const end_a = alloc.create(End) catch @panic("out of memory");
    end_a.* = .{ .pair = pair, .inbox = &pair.b_to_a, .outbox = &pair.a_to_b, .alloc_ref = alloc };
    const end_b = alloc.create(End) catch @panic("out of memory");
    end_b.* = .{ .pair = pair, .inbox = &pair.a_to_b, .outbox = &pair.b_to_a, .alloc_ref = alloc };
    return .{ .pair = pair, .end_a = end_a, .end_b = end_b };
}

pub fn transportOf(end: *End) transport_mod.Transport {
    return .{ .ctx = end, .send_fn = End.send, .recv_fn = End.recv, .close_fn = End.close };
}
GRPC_RUNTIME_EOF
)

(define zig-dynamic-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const wire = @import("wire.zig");
const channel_mod = @import("channel.zig");
const endpoint_mod = @import("endpoint.zig");
const server_mod = @import("server.zig");
const status_mod = @import("status.zig");
const transport_mod = @import("transport.zig");

pub const Status = status_mod.Status;
pub const CallContext = endpoint_mod.CallContext;
pub const Channel = channel_mod.Channel;
pub const Server = server_mod.Server;

// FieldDescriptorProto.Type values (descriptor.proto).
pub const type_double: i32 = 1;
pub const type_float: i32 = 2;
pub const type_int64: i32 = 3;
pub const type_uint64: i32 = 4;
pub const type_int32: i32 = 5;
pub const type_fixed64: i32 = 6;
pub const type_fixed32: i32 = 7;
pub const type_bool: i32 = 8;
pub const type_string: i32 = 9;
pub const type_group: i32 = 10;
pub const type_message: i32 = 11;
pub const type_bytes: i32 = 12;
pub const type_uint32: i32 = 13;
pub const type_enum: i32 = 14;
pub const type_sfixed32: i32 = 15;
pub const type_sfixed64: i32 = 16;
pub const type_sint32: i32 = 17;
pub const type_sint64: i32 = 18;

const label_repeated: i32 = 3;

pub const FieldModel = struct {
    number: u32 = 0,
    name: []const u8 = "",
    type: i32 = 0,
    repeated: bool = false,
    type_name: []const u8 = "", // for type_message, e.g. ".echo.EchoRequest"
};

pub const MessageModel = struct {
    full_name: []const u8,
    fields: std.AutoHashMap(u32, *FieldModel),
    by_name: std.StringHashMap(u32),
};

pub const MethodModel = struct {
    name: []const u8 = "",
    path: []const u8 = "",
    kind: server_mod.MethodKind = .unary,
    input: ?*MessageModel = null,
    output: ?*MessageModel = null,
};

pub const ServiceModel = struct {
    full_name: []const u8,
    methods: std.StringHashMap(*MethodModel),
};

/// Parsed descriptor set: messages and services by full name.
/// Message keys carry the leading dot (".echo.EchoRequest"), matching
/// FieldDescriptorProto.type_name; service keys do not ("echo.Echo").
pub const FileModel = struct {
    alloc: std.mem.Allocator,
    messages: std.StringHashMap(*MessageModel),
    services: std.StringHashMap(*ServiceModel),

    pub fn message(self: *FileModel, full_name: []const u8) ?*MessageModel {
        return self.messages.get(full_name);
    }

    pub fn service(self: *FileModel, full_name: []const u8) ?*ServiceModel {
        return self.services.get(full_name);
    }
};

pub const GenericValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    bytes: []const u8,
    message: *GenericMessage,
};

/// A message as field number -> list of values (descriptor order).
///
/// Generic values: varint family -> int/bool, string -> string,
/// bytes/message -> bytes / GenericMessage, fixed/float ->
/// int / double.
///
/// Fields not in the model are retained as raw encoded chunks in
/// unknown (protobuf unknown-field retention): a decode -> encode
/// round trip re-emits them after the known fields, so intermediate
/// hops do not strip newer fields.
pub const GenericMessage = struct {
    model: ?*MessageModel = null,
    alloc: std.mem.Allocator,
    values: std.AutoHashMap(u32, std.ArrayList(GenericValue)),
    unknown: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, model: ?*MessageModel) GenericMessage {
        return .{ .alloc = alloc, .model = model, .values = std.AutoHashMap(u32, std.ArrayList(GenericValue)).init(alloc) };
    }

    pub fn set(self: *GenericMessage, alloc: std.mem.Allocator, number: u32, value: GenericValue) *GenericMessage {
        var list: std.ArrayList(GenericValue) = .empty;
        list.append(alloc, value) catch {};
        self.values.put(number, list) catch {};
        return self;
    }

    pub fn add(self: *GenericMessage, alloc: std.mem.Allocator, number: u32, value: GenericValue) *GenericMessage {
        const gop = self.values.getOrPut(number) catch return self;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(alloc, value) catch {};
        return self;
    }

    pub fn get(self: *GenericMessage, number: u32) ?GenericValue {
        const list = self.values.get(number) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[0];
    }

    pub fn getString(self: *GenericMessage, number: u32) []const u8 {
        const v = self.get(number) orelse return "";
        return switch (v) {
            .string => |s| s,
            else => "",
        };
    }

    pub fn getInt(self: *GenericMessage, number: u32) i64 {
        const v = self.get(number) orelse return 0;
        return switch (v) {
            .boolean => |b| if (b) @as(i64, 1) else 0,
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Generic protobuf codec
// ---------------------------------------------------------------------------

pub const PbField = struct {
    number: u32 = 0,
    wire: u32 = 0,
    varint: u64 = 0,
    bytes: []const u8 = "",
    chunk: []const u8 = "",
};

pub const PbReader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) PbReader {
        return .{ .buf = buf };
    }

    pub fn varint(self: *PbReader) ?u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return null;
            const b = self.buf[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
            if (shift >= 63) return null;
        }
    }

    fn lenBytes(self: *PbReader) ?[]const u8 {
        const n64 = self.varint() orelse return null;
        const n: usize = @intCast(n64);
        if (self.pos + n > self.buf.len) return null;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    pub fn next(self: *PbReader) ?PbField {
        if (self.pos >= self.buf.len) return null;
        const start = self.pos;
        const tag = self.varint() orelse return null;
        var field = PbField{ .number = @intCast(tag >> 3), .wire = @intCast(tag & 7) };
        switch (field.wire) {
            0 => field.varint = self.varint() orelse return null,
            2 => field.bytes = self.lenBytes() orelse return null,
            1 => {
                if (self.pos + 8 > self.buf.len) return null;
                field.bytes = self.buf[self.pos .. self.pos + 8];
                self.pos += 8;
            },
            5 => {
                if (self.pos + 4 > self.buf.len) return null;
                field.bytes = self.buf[self.pos .. self.pos + 4];
                self.pos += 4;
            },
            else => return null,
        }
        field.chunk = self.buf[start..self.pos];
        return field;
    }
};

fn wireTypeOf(field_type: i32) i32 {
    return switch (field_type) {
        type_int64, type_uint64, type_int32, type_bool, type_uint32, type_enum, type_sint32, type_sint64 => 0,
        type_fixed64, type_sfixed64, type_double => 1,
        type_string, type_bytes, type_message, type_group => 2,
        type_fixed32, type_sfixed32, type_float => 5,
        else => -1,
    };
}

fn encodeVarint(out: *std.Io.Writer.Allocating, value: u64) void {
    var v = value;
    while ((v & ~@as(u64, 0x7f)) != 0) {
        out.writer.writeByte(@intCast((v & 0x7f) | 0x80)) catch {};
        v >>= 7;
    }
    out.writer.writeByte(@intCast(v & 0xff)) catch {};
}

fn zigzagEncode(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

fn zigzagDecode(v: u64) i64 {
    const uv: i64 = @bitCast(v >> 1);
    const neg: i64 = -@as(i64, @intCast(v & 1));
    return uv ^ neg;
}

fn valueAsInt(value: GenericValue) i64 {
    return switch (value) {
        .boolean => |b| if (b) @as(i64, 1) else 0,
        .int => |i| i,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}

pub const EncodeResult = status_mod.CallResult([]u8);

pub fn encodeGeneric(alloc: std.mem.Allocator, model: *MessageModel, message: *GenericMessage, file: *FileModel) EncodeResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var numbers: std.ArrayList(u32) = .empty;
    defer numbers.deinit(alloc);
    var key_it = message.values.keyIterator();
    while (key_it.next()) |k| numbers.append(alloc, k.*) catch {};
    std.mem.sort(u32, numbers.items, {}, std.sort.asc(u32));
    for (numbers.items) |number| {
        const field = model.fields.get(number) orelse
            return .{ .status = Status.init(wire.codeInvalidArgument, "unknown field for message") };
        const values = message.values.get(number).?;
        if (field.repeated) {
            for (values.items) |value| {
                const st = encodeValue(alloc, &out, field, value, file);
                if (!st.isOk()) return .{ .status = st };
            }
        } else if (values.items.len > 0) {
            const st = encodeValue(alloc, &out, field, values.items[0], file);
            if (!st.isOk()) return .{ .status = st };
        }
    }
    for (message.unknown.items) |chunk| {
        out.writer.writeAll(chunk) catch {};
    }
    return .{ .ok = out.toOwnedSlice() catch return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") } };
}

fn encodeValue(alloc: std.mem.Allocator, out: *std.Io.Writer.Allocating, field: *FieldModel, value: GenericValue, file: *FileModel) Status {
    const wt = wireTypeOf(field.type);
    if (wt < 0) return Status.init(wire.codeInvalidArgument, "unsupported field type");
    encodeVarint(out, (@as(u64, field.number) << 3) | @as(u64, @intCast(wt)));
    switch (wt) {
        0 => {
            var v: u64 = undefined;
            if (field.type == type_sint32 or field.type == type_sint64) {
                v = zigzagEncode(valueAsInt(value));
                if (field.type == type_sint32) v &= 0xffffffff;
            } else if (field.type == type_bool) {
                v = if (valueAsInt(value) != 0) 1 else 0;
            } else {
                v = @bitCast(valueAsInt(value));
            }
            encodeVarint(out, v);
        },
        1 => {
            var v: u64 = undefined;
            if (field.type == type_double) {
                const d: f64 = switch (value) {
                    .float => |f| f,
                    .int => |i| @floatFromInt(i),
                    else => 0,
                };
                v = @bitCast(d);
            } else {
                v = @bitCast(valueAsInt(value));
            }
            for (0..8) |i| {
                out.writer.writeByte(@intCast((v >> @intCast(8 * i)) & 0xff)) catch {};
            }
        },
        5 => {
            var v: u32 = undefined;
            if (field.type == type_float) {
                const f: f32 = switch (value) {
                    .float => |x| @floatCast(x),
                    .int => |i| @floatFromInt(i),
                    else => 0,
                };
                v = @bitCast(f);
            } else {
                v = @truncate(@as(u64, @bitCast(valueAsInt(value))));
            }
            for (0..4) |i| {
                out.writer.writeByte(@intCast((v >> @intCast(8 * i)) & 0xff)) catch {};
            }
        },
        else => {
            var data: []const u8 = undefined;
            if (field.type == type_string) {
                data = switch (value) {
                    .string => |s| s,
                    else => return Status.init(wire.codeInvalidArgument, "value does not match field type"),
                };
            } else if (field.type == type_message) {
                const nested = switch (value) {
                    .message => |m| m,
                    else => return Status.init(wire.codeInvalidArgument, "value does not match field type"),
                };
                const nested_model = file.message(field.type_name) orelse
                    return Status.init(wire.codeInvalidArgument, "unknown nested message");
                switch (encodeGeneric(alloc, nested_model, nested, file)) {
                    .ok => |bytes| data = bytes,
                    .status => |st| return st,
                }
            } else {
                data = switch (value) {
                    .bytes => |b| b,
                    .string => |s| s,
                    else => return Status.init(wire.codeInvalidArgument, "value does not match field type"),
                };
            }
            encodeVarint(out, data.len);
            out.writer.writeAll(data) catch {};
        },
    }
    return Status.ok();
}

pub const DecodeResult = status_mod.CallResult(*GenericMessage);

pub fn decodeGeneric(alloc: std.mem.Allocator, model: *MessageModel, data: []const u8, file: *FileModel) *GenericMessage {
    const message = alloc.create(GenericMessage) catch @panic("out of memory");
    message.* = GenericMessage.init(alloc, model);
    var reader = PbReader.init(data);
    while (reader.next()) |raw| {
        const field = model.fields.get(raw.number) orelse {
            // Unknown field: retain the raw encoded chunk verbatim.
            const chunk = alloc.dupe(u8, raw.chunk) catch continue;
            message.unknown.append(alloc, chunk) catch {};
            continue;
        };
        _ = message.add(alloc, raw.number, decodeValue(alloc, field, raw, file));
    }
    return message;
}

fn decodeValue(alloc: std.mem.Allocator, field: *FieldModel, raw: PbField, file: *FileModel) GenericValue {
    switch (raw.wire) {
        0 => {
            if (field.type == type_bool) return .{ .boolean = raw.varint != 0 };
            if (field.type == type_sint32 or field.type == type_sint64) return .{ .int = zigzagDecode(raw.varint) };
            if (field.type == type_int32 or field.type == type_enum) {
                const signed: i32 = @truncate(@as(i64, @bitCast(raw.varint)));
                return .{ .int = signed };
            }
            return .{ .int = @bitCast(raw.varint) };
        },
        1 => {
            var v: u64 = 0;
            for (0..8) |i| v |= @as(u64, raw.bytes[i]) << @intCast(8 * i);
            if (field.type == type_double) return .{ .float = @bitCast(v) };
            return .{ .int = @bitCast(v) };
        },
        5 => {
            var v: u32 = 0;
            for (0..4) |i| v |= @as(u32, raw.bytes[i]) << @intCast(8 * i);
            if (field.type == type_float) {
                const f: f32 = @bitCast(v);
                return .{ .float = f };
            }
            return .{ .int = v };
        },
        else => {
            if (field.type == type_string) {
                return .{ .string = alloc.dupe(u8, raw.bytes) catch "" };
            }
            if (field.type == type_message) {
                const nested_model = file.message(field.type_name) orelse
                    return .{ .bytes = alloc.dupe(u8, raw.bytes) catch "" };
                return .{ .message = decodeGeneric(alloc, nested_model, raw.bytes, file) };
            }
            return .{ .bytes = alloc.dupe(u8, raw.bytes) catch "" };
        },
    }
}

// ---------------------------------------------------------------------------
// Descriptor set parsing
// ---------------------------------------------------------------------------

/// Parse FileDescriptorSet bytes into a FileModel. All model storage
/// is allocated with alloc and owned by the FileModel's lifetime.
pub fn parseDescriptorSet(alloc: std.mem.Allocator, data: []const u8) *FileModel {
    const file = alloc.create(FileModel) catch @panic("out of memory");
    file.* = .{
        .alloc = alloc,
        .messages = std.StringHashMap(*MessageModel).init(alloc),
        .services = std.StringHashMap(*ServiceModel).init(alloc),
    };
    var pending: std.ArrayList(struct { pkg: []const u8, bytes: []const u8 }) = .empty;
    defer pending.deinit(alloc);
    var reader = PbReader.init(data);
    while (reader.next()) |f| {
        if (f.number != 1) continue;
        var pkg: []const u8 = "";
        var message_types: std.ArrayList([]const u8) = .empty;
        defer message_types.deinit(alloc);
        var service_types: std.ArrayList([]const u8) = .empty;
        defer service_types.deinit(alloc);
        var fr = PbReader.init(f.bytes);
        while (fr.next()) |ff| {
            switch (ff.number) {
                2 => pkg = alloc.dupe(u8, ff.bytes) catch "",
                4 => message_types.append(alloc, ff.bytes) catch {},
                6 => service_types.append(alloc, ff.bytes) catch {},
                else => {},
            }
        }
        for (message_types.items) |m| parseMessage(alloc, pkg, m, file);
        for (service_types.items) |s| pending.append(alloc, .{ .pkg = pkg, .bytes = s }) catch {};
    }
    for (pending.items) |p| parseService(alloc, p.pkg, p.bytes, file);
    return file;
}

fn parseMessage(alloc: std.mem.Allocator, prefix: []const u8, data: []const u8, file: *FileModel) void {
    var name: []const u8 = "";
    var raw_fields: std.ArrayList([]const u8) = .empty;
    defer raw_fields.deinit(alloc);
    var nested: std.ArrayList([]const u8) = .empty;
    defer nested.deinit(alloc);
    var reader = PbReader.init(data);
    while (reader.next()) |f| {
        switch (f.number) {
            1 => name = alloc.dupe(u8, f.bytes) catch "",
            2 => raw_fields.append(alloc, f.bytes) catch {},
            3 => nested.append(alloc, f.bytes) catch {},
            else => {},
        }
    }
    const full_name = if (prefix.len == 0) name else std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, name }) catch name;
    const model = alloc.create(MessageModel) catch return;
    model.* = .{
        .full_name = full_name,
        .fields = std.AutoHashMap(u32, *FieldModel).init(alloc),
        .by_name = std.StringHashMap(u32).init(alloc),
    };
    for (raw_fields.items) |field_bytes| {
        const field = parseField(alloc, field_bytes);
        model.by_name.put(field.name, field.number) catch {};
        model.fields.put(field.number, field) catch {};
    }
    const key = std.fmt.allocPrint(alloc, ".{s}", .{full_name}) catch return;
    file.messages.put(key, model) catch {};
    for (nested.items) |nested_bytes| {
        parseMessage(alloc, full_name, nested_bytes, file);
    }
}

fn parseField(alloc: std.mem.Allocator, data: []const u8) *FieldModel {
    const field = alloc.create(FieldModel) catch @panic("out of memory");
    field.* = .{};
    var reader = PbReader.init(data);
    while (reader.next()) |f| {
        switch (f.number) {
            1 => field.name = alloc.dupe(u8, f.bytes) catch "",
            3 => field.number = @intCast(f.varint),
            4 => field.repeated = f.varint == label_repeated,
            5 => field.type = @intCast(@as(i64, @bitCast(f.varint))),
            6 => field.type_name = alloc.dupe(u8, f.bytes) catch "",
            else => {},
        }
    }
    return field;
}

fn kindOf(client_streaming: bool, server_streaming: bool) server_mod.MethodKind {
    if (client_streaming and server_streaming) return .bidi;
    if (server_streaming) return .server_streaming;
    if (client_streaming) return .client_streaming;
    return .unary;
}

fn kindName(kind: server_mod.MethodKind) []const u8 {
    return switch (kind) {
        .unary => "unary",
        .server_streaming => "server-streaming",
        .client_streaming => "client-streaming",
        .bidi => "bidi",
    };
}

fn parseService(alloc: std.mem.Allocator, pkg: []const u8, data: []const u8, file: *FileModel) void {
    var name: []const u8 = "";
    var raw_methods: std.ArrayList([]const u8) = .empty;
    defer raw_methods.deinit(alloc);
    var reader = PbReader.init(data);
    while (reader.next()) |f| {
        switch (f.number) {
            1 => name = alloc.dupe(u8, f.bytes) catch "",
            2 => raw_methods.append(alloc, f.bytes) catch {},
            else => {},
        }
    }
    const full_name = if (pkg.len == 0) name else std.fmt.allocPrint(alloc, "{s}.{s}", .{ pkg, name }) catch name;
    const service = alloc.create(ServiceModel) catch return;
    service.* = .{ .full_name = full_name, .methods = std.StringHashMap(*MethodModel).init(alloc) };
    for (raw_methods.items) |method_bytes| {
        var mname: []const u8 = "";
        var input_type: []const u8 = "";
        var output_type: []const u8 = "";
        var client_streaming = false;
        var server_streaming = false;
        var mr = PbReader.init(method_bytes);
        while (mr.next()) |mf| {
            switch (mf.number) {
                1 => mname = alloc.dupe(u8, mf.bytes) catch "",
                2 => input_type = alloc.dupe(u8, mf.bytes) catch "",
                3 => output_type = alloc.dupe(u8, mf.bytes) catch "",
                5 => client_streaming = mf.varint != 0,
                6 => server_streaming = mf.varint != 0,
                else => {},
            }
        }
        const method = alloc.create(MethodModel) catch continue;
        method.* = .{
            .name = mname,
            .path = std.fmt.allocPrint(alloc, "/{s}/{s}", .{ full_name, mname }) catch "",
            .kind = kindOf(client_streaming, server_streaming),
            .input = file.message(input_type),
            .output = file.message(output_type),
        };
        service.methods.put(mname, method) catch {};
    }
    file.services.put(full_name, service) catch {};
}

// ---------------------------------------------------------------------------
// Client / server surfaces
// ---------------------------------------------------------------------------

/// Adapts a (MessageModel, GenericMessage) pair to the Channel
/// marshal/unmarshal contract.
pub const BoundMessage = struct {
    model: *MessageModel,
    file: *FileModel,
    generic: *GenericMessage,

    pub fn marshalDc(self: *const BoundMessage, alloc: std.mem.Allocator) []u8 {
        return switch (encodeGeneric(alloc, self.model, self.generic, self.file)) {
            .ok => |bytes| bytes,
            .status => &.{},
        };
    }

    pub fn unmarshalDc(self: *BoundMessage, alloc: std.mem.Allocator, data: []const u8) void {
        self.generic = decodeGeneric(alloc, self.model, data, self.file);
    }
};

/// Receiving stream of generic responses.
pub const DynamicStream = struct {
    stream: channel_mod.ClientStream,
    output: *MessageModel,
    file: *FileModel,

    /// Next response; end means the stream completed OK.
    pub fn recv(self: *DynamicStream) status_mod.RecvResult(*GenericMessage) {
        const alloc = self.stream.endpoint.alloc;
        var bound = BoundMessage{ .model = self.output, .file = self.file, .generic = GenericMessageAlloc.create(alloc, self.output) };
        switch (self.stream.recvInto(&bound)) {
            .message => return .{ .message = bound.generic },
            .end => return .end,
            .status => |st| return .{ .status = st },
        }
    }

    pub fn deinit(self: *DynamicStream) void {
        self.stream.deinit();
    }
};

const GenericMessageAlloc = struct {
    fn create(alloc: std.mem.Allocator, model: *MessageModel) *GenericMessage {
        const msg = alloc.create(GenericMessage) catch @panic("out of memory");
        msg.* = GenericMessage.init(alloc, model);
        return msg;
    }
};

fn newGeneric(alloc: std.mem.Allocator, model: *MessageModel) *GenericMessage {
    return GenericMessageAlloc.create(alloc, model);
}

/// Runtime-built client: methods resolve from the FileModel.
pub const DynamicClient = struct {
    channel: *Channel,
    model: *FileModel,

    pub fn init(channel: *Channel, model: *FileModel) DynamicClient {
        return .{ .channel = channel, .model = model };
    }

    fn method(self: *DynamicClient, service_name: []const u8, method_name: []const u8) CallResult(*MethodModel) {
        const svc = self.model.service(service_name) orelse
            return .{ .status = Status.init(wire.codeInvalidArgument, "unknown service") };
        const m = svc.methods.get(method_name) orelse
            return .{ .status = Status.init(wire.codeInvalidArgument, "unknown method") };
        return .{ .ok = m };
    }

    pub fn unary(self: *DynamicClient, service_name: []const u8, method_name: []const u8, req: *GenericMessage, metadata: ?*const transport_mod.Metadata, timeout_ms: ?u64) CallResult(*GenericMessage) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.channel.endpoint.alloc;
        var bound_req = BoundMessage{ .model = m.input.?, .file = self.model, .generic = req };
        var bound_resp = BoundMessage{ .model = m.output.?, .file = self.model, .generic = newGeneric(alloc, m.output.?) };
        const st = self.channel.unary(m.path, &bound_req, &bound_resp, metadata, timeout_ms);
        if (!st.isOk()) return .{ .status = st };
        return .{ .ok = bound_resp.generic };
    }

    pub fn serverStream(self: *DynamicClient, service_name: []const u8, method_name: []const u8, req: *GenericMessage, metadata: ?*const transport_mod.Metadata, timeout_ms: ?u64) CallResult(DynamicStream) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        var bound_req = BoundMessage{ .model = m.input.?, .file = self.model, .generic = req };
        switch (self.channel.serverStream(m.path, &bound_req, metadata, timeout_ms)) {
            .ok => |stream| return .{ .ok = .{ .stream = stream, .output = m.output.?, .file = self.model } },
            .status => |st| return .{ .status = st },
        }
    }

    pub fn clientStream(self: *DynamicClient, service_name: []const u8, method_name: []const u8, reqs: []const *GenericMessage, metadata: ?*const transport_mod.Metadata, timeout_ms: ?u64) CallResult(*GenericMessage) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.channel.endpoint.alloc;
        var bound = alloc.alloc(BoundMessage, reqs.len) catch return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
        for (reqs, 0..) |r, i| bound[i] = .{ .model = m.input.?, .file = self.model, .generic = r };
        var bound_resp = BoundMessage{ .model = m.output.?, .file = self.model, .generic = newGeneric(alloc, m.output.?) };
        const st = self.channel.clientStreamCall(m.path, bound, &bound_resp, metadata, timeout_ms);
        if (!st.isOk()) return .{ .status = st };
        return .{ .ok = bound_resp.generic };
    }

    pub fn bidi(self: *DynamicClient, service_name: []const u8, method_name: []const u8, reqs: []const *GenericMessage, metadata: ?*const transport_mod.Metadata, timeout_ms: ?u64) CallResult(DynamicStream) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.channel.endpoint.alloc;
        var bound = alloc.alloc(BoundMessage, reqs.len) catch return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
        for (reqs, 0..) |r, i| bound[i] = .{ .model = m.input.?, .file = self.model, .generic = r };
        switch (self.channel.bidi(m.path, bound, metadata, timeout_ms)) {
            .ok => |stream| return .{ .ok = .{ .stream = stream, .output = m.output.?, .file = self.model } },
            .status => |st| return .{ .status = st },
        }
    }
};

pub fn CallResult(comptime T: type) type {
    return status_mod.CallResult(T);
}

/// Collect all responses of a dynamic stream (scenario drivers).
pub fn collectStream(alloc: std.mem.Allocator, stream: *DynamicStream) CallResult([]*GenericMessage) {
    var out: std.ArrayList(*GenericMessage) = .empty;
    while (true) {
        switch (stream.recv()) {
            .message => |msg| out.append(alloc, msg) catch return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") },
            .end => return .{ .ok = out.items },
            .status => |st| return .{ .status = st },
        }
    }
}

// Handler signatures for registerDynamicService.
pub const DynamicRecvFn = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) status_mod.RecvResult(*GenericMessage),

    pub fn recv(self: DynamicRecvFn) status_mod.RecvResult(*GenericMessage) {
        return self.func(self.ctx);
    }
};

pub const DynamicSendFn = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, resp: *GenericMessage) Status,

    pub fn send(self: DynamicSendFn, resp: *GenericMessage) Status {
        return self.func(self.ctx, resp);
    }
};

/// Implements a service with generic messages (vtable).
pub const DynamicHandler = struct {
    ctx: *anyopaque,
    unary_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, method: *MethodModel, req: *GenericMessage) CallResult(*GenericMessage),
    server_stream_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, method: *MethodModel, req: *GenericMessage, send_fn: DynamicSendFn) Status,
    client_stream_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, method: *MethodModel, recv_fn: DynamicRecvFn) CallResult(*GenericMessage),
    bidi_fn: *const fn (ctx: *anyopaque, call_ctx: *CallContext, method: *MethodModel, recv_fn: DynamicRecvFn, send_fn: DynamicSendFn) Status,
};

const MethodBinding = struct {
    file: *FileModel,
    handler: *const DynamicHandler,
    method: *MethodModel,
    alloc: std.mem.Allocator,
};

fn dynamicAdapter(ctx: *anyopaque, call_ctx: *CallContext, reqs: *server_mod.RequestStream, sink: server_mod.Sink) Status {
    const binding: *MethodBinding = @ptrCast(@alignCast(ctx));
    const m = binding.method;
    const alloc = binding.alloc;
    const handler = binding.handler;

    const RecvCtx = struct {
        reqs: *server_mod.RequestStream,
        input_model: *MessageModel,
        file: *FileModel,
        alloc: std.mem.Allocator,

        fn recvFn(raw: *anyopaque) status_mod.RecvResult(*GenericMessage) {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (self.reqs.recvRaw()) {
                .message => |payload| {
                    defer self.alloc.free(payload);
                    return .{ .message = decodeGeneric(self.alloc, self.input_model, payload, self.file) };
                },
                .end => return .end,
                .status => |st| return .{ .status = st },
            }
        }
    };
    const SendCtx = struct {
        sink: server_mod.Sink,
        output_model: *MessageModel,
        file: *FileModel,
        alloc: std.mem.Allocator,

        fn sendFn(raw: *anyopaque, resp: *GenericMessage) Status {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (encodeGeneric(self.alloc, self.output_model, resp, self.file)) {
                .ok => |bytes| {
                    defer self.alloc.free(bytes);
                    return self.sink.send(bytes);
                },
                .status => |st| return st,
            }
        }
    };

    var recv_ctx = RecvCtx{ .reqs = reqs, .input_model = m.input.?, .file = binding.file, .alloc = alloc };
    var send_ctx = SendCtx{ .sink = sink, .output_model = m.output.?, .file = binding.file, .alloc = alloc };
    const recv_fn = DynamicRecvFn{ .ctx = &recv_ctx, .func = RecvCtx.recvFn };
    const send_fn = DynamicSendFn{ .ctx = &send_ctx, .func = SendCtx.sendFn };

    switch (m.kind) {
        .unary => {
            const req = switch (recv_fn.recv()) {
                .message => |msg| msg,
                .end => return Status.init(wire.codeInternal, "unary call closed with no request"),
                .status => |st| return st,
            };
            switch (handler.unary_fn(handler.ctx, call_ctx, m, req)) {
                .ok => |resp| return send_fn.send(resp),
                .status => |st| return st,
            }
        },
        .server_streaming => {
            const req = switch (recv_fn.recv()) {
                .message => |msg| msg,
                .end => return Status.init(wire.codeInternal, "server-streaming call closed with no request"),
                .status => |st| return st,
            };
            return handler.server_stream_fn(handler.ctx, call_ctx, m, req, send_fn);
        },
        .client_streaming => {
            switch (handler.client_stream_fn(handler.ctx, call_ctx, m, recv_fn)) {
                .ok => |resp| return send_fn.send(resp),
                .status => |st| return st,
            }
        },
        .bidi => return handler.bidi_fn(handler.ctx, call_ctx, m, recv_fn, send_fn),
    }
}

/// Register a runtime-built service on a Server.
pub fn registerDynamicService(server: *Server, file: *FileModel, service_name: []const u8, handler: *const DynamicHandler) void {
    const alloc = server.alloc;
    const service = file.service(service_name) orelse return;
    var methods: std.ArrayList(server_mod.Method) = .empty;
    var it = service.methods.valueIterator();
    while (it.next()) |mp| {
        const m = mp.*;
        const binding = alloc.create(MethodBinding) catch continue;
        binding.* = .{ .file = file, .handler = handler, .method = m, .alloc = alloc };
        methods.append(alloc, .{
            .name = m.name,
            .path = m.path,
            .kind = m.kind,
            .ctx = binding,
            .handler = dynamicAdapter,
        }) catch {};
    }
    server.registerService(.{ .name = service.full_name, .methods = methods.items });
}
GRPC_RUNTIME_EOF
)


(define zig-sidecar-body
#<<GRPC_RUNTIME_EOF
const std = @import("std");
const transport_mod = @import("transport.zig");

/// Transport over the Rust WebRTC-Direct sidecar: the sidecar
/// owns DTLS/SCTP/TURN and bridges one datachannel to a local
/// TCP socket using u32 big-endian length-prefixed messages
/// (one prefix per DataChannel message). std.net only; `host`
/// must be an IPv4 literal (the sidecar is local).
pub const SidecarTransport = struct {
    stream: std.net.Stream,
    buf: std.ArrayList(u8) = .empty,
    closed: bool = false,

    pub fn connect(alloc: std.mem.Allocator, host: []const u8, port: u16) !*SidecarTransport {
        const addr = try std.net.Address.parseIp4(host, port);
        const stream = try std.net.tcpConnectToAddress(addr);
        const self = try alloc.create(SidecarTransport);
        self.* = .{ .stream = stream };
        return self;
    }

    pub fn transport(self: *SidecarTransport) transport_mod.Transport {
        return .{
            .ctx = self,
            .send_fn = sendImpl,
            .recv_fn = recvImpl,
            .close_fn = closeImpl,
        };
    }

    fn fill(self: *SidecarTransport, alloc: std.mem.Allocator, need: usize) !void {
        var tmp: [65536]u8 = undefined;
        while (self.buf.items.len < need) {
            const n = try self.stream.read(&tmp);
            if (n == 0) return error.Closed;
            try self.buf.appendSlice(alloc, tmp[0..n]);
        }
    }

    fn sendImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *SidecarTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.Closed;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(data.len), .big);
        try self.stream.writeAll(&header);
        try self.stream.writeAll(data);
    }

    fn recvImpl(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 {
        const self: *SidecarTransport = @ptrCast(@alignCast(ctx));
        self.fill(alloc, 4) catch return null;
        const len = std.mem.readInt(u32, self.buf.items[0..4], .big);
        // Consume the header.
        const rest = try alloc.dupe(u8, self.buf.items[4..]);
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(alloc, rest);
        alloc.free(rest);
        self.fill(alloc, len) catch return null;
        const payload = try alloc.dupe(u8, self.buf.items[0..len]);
        const rest2 = try alloc.dupe(u8, self.buf.items[len..]);
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(alloc, rest2);
        alloc.free(rest2);
        return payload;
    }

    fn closeImpl(ctx: *anyopaque) void {
        const self: *SidecarTransport = @ptrCast(@alignCast(ctx));
        self.closed = true;
        self.stream.close();
    }
};
GRPC_RUNTIME_EOF
)

(define zig-root-body
#<<GRPC_RUNTIME_EOF
/// grpc-over-DataChannels runtime for Zig (stdlib only, no external
/// packages). Wire tables in wire.zig are generated by grpc-dc
/// codegen; see ../SPEC.md.
pub const wire = @import("wire.zig");
pub const status = @import("status.zig");
pub const codec = @import("codec.zig");
pub const transport = @import("transport.zig");
pub const endpoint = @import("endpoint.zig");
pub const channel = @import("channel.zig");
pub const server = @import("server.zig");
pub const memory_transport = @import("memory_transport.zig");
pub const sidecar_transport = @import("sidecar_transport.zig");
pub const http2_transport = @import("http2_transport.zig");
pub const dynamic = @import("dynamic.zig");
pub const structdc = @import("structdc.zig");
GRPC_RUNTIME_EOF
)

;; Frame dispatch: generated from spec.rkt's frame table, one arm per
;; frame type, spliced into the endpoint body.

(define zig-dispatch-arms
  '((HEADERS . "self.onHeaders(frame.stream_id, frame.payload);")
    (DATA . "if (self.stream(frame.stream_id)) |input| {\n                const owned = self.alloc.dupe(u8, frame.payload) catch return;\n                input.put(self.alloc, .{ .kind = .data, .payload = owned });\n            }")
    (TRAILERS . "self.onTerminal(frame.stream_id, frame.payload, .trailers);")
    (HALF-CLOSE . "if (self.stream(frame.stream_id)) |input| {\n                input.put(self.alloc, .{ .kind = .half_close });\n            }")
    (RST . "self.onTerminal(frame.stream_id, frame.payload, .rst);")))

(define (pascal-zig sym) ; HALF-CLOSE -> HalfClose
  (apply string-append
         (for/list ([part (in-list (string-split (symbol->string sym) "-"))])
           (string-append (string (char-upcase (string-ref part 0)))
                          (string-downcase (substring part 1))))))

(define (emit-zig-dispatch)
  (define arms
    (for/list ([e (in-list frame-table)] [i (in-naturals)])
      (define arm (assoc (first e) zig-dispatch-arms))
      (unless arm (error 'runtime-zig "no Zig dispatch arm for ~a" (first e)))
      (format "~a (frame.type == wire.frame~a) {\n            ~a\n        "
              (if (= i 0) "if" "} else if")
              (pascal-zig (first e)) (cdr arm))))
  (string-append
   (apply string-append arms)
   "} else {\n"
   "            // Unknown frame type: ignore for forward compatibility.\n"
   "        }"))

(define (emit-zig-runtime-files)
  (list
   (cons "grpcdc/status.zig" zig-status-body)
   (cons "grpcdc/codec.zig" zig-codec-body)
   (cons "grpcdc/transport.zig" zig-transport-body)
   (cons "grpcdc/endpoint.zig"
         (string-replace zig-endpoint-body "@@FRAME_DISPATCH@@" (emit-zig-dispatch)))
   (cons "grpcdc/channel.zig" zig-channel-body)
   (cons "grpcdc/server.zig" zig-server-body)
   (cons "grpcdc/memory_transport.zig" zig-memory-body)
   (cons "grpcdc/sidecar_transport.zig" zig-sidecar-body)
   (cons "grpcdc/dynamic.zig" zig-dynamic-body)
   (cons "grpcdc/structdc.zig" zig-structdc-body)
   (cons "grpcdc/grpcdc.zig" zig-root-body)))

(define zig-structdc-body
#<<GRPC_RUNTIME_EOF
// Descriptor-driven struct codec (layout v1, DCS1): the
// packed struct format from SPEC.md, implemented in pure Zig
// over a minimal internal dynamic model so Wasm builds (no
// native cdylib) transcode protobuf <-> struct without the
// FFI bridge. Byte-identical to the shared Rust
// implementation (conformance/struct).

const std = @import("std");

pub const Error = error{ StructCodec, OutOfMemory };

const t_double: i32 = 1;
const t_float: i32 = 2;
const t_int64: i32 = 3;
const t_uint64: i32 = 4;
const t_int32: i32 = 5;
const t_fixed64: i32 = 6;
const t_fixed32: i32 = 7;
const t_bool: i32 = 8;
const t_string: i32 = 9;
const t_group: i32 = 10;
const t_message: i32 = 11;
const t_bytes: i32 = 12;
const t_uint32: i32 = 13;
const t_enum: i32 = 14;
const t_sfixed32: i32 = 15;
const t_sfixed64: i32 = 16;
const t_sint32: i32 = 17;
const t_sint64: i32 = 18;

const FieldM = struct {
    number: u32 = 0,
    name: []const u8 = "",
    ftype: i32 = 0,
    repeated: bool = false,
    type_name: []const u8 = "",
};

const MsgM = struct {
    full_name: []const u8,
    fields: std.AutoHashMap(u32, *FieldM),
    map_entry: bool = false,
};

const FileM = struct {
    messages: std.StringHashMap(*MsgM),
};

const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    bytes: []const u8,
    message: *Generic,
};

const Generic = struct {
    values: std.AutoHashMap(u32, std.ArrayList(Value)),
    unknown: std.ArrayList([]u8) = .empty,

    fn init(alloc: std.mem.Allocator) Generic {
        return .{ .values = std.AutoHashMap(u32, std.ArrayList(Value)).init(alloc) };
    }
    fn add(self: *Generic, alloc: std.mem.Allocator, number: u32, value: Value) !void {
        const gop = try self.values.getOrPut(number);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, value);
    }
    fn set(self: *Generic, alloc: std.mem.Allocator, number: u32, value: Value) !void {
        var list: std.ArrayList(Value) = .empty;
        try list.append(alloc, value);
        try self.values.put(number, list);
    }
    fn get(self: *Generic, number: u32) ?Value {
        const list = self.values.get(number) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[0];
    }
    fn getAll(self: *Generic, number: u32) []const Value {
        const list = self.values.get(number) orelse return &[_]Value{};
        return list.items;
    }
};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn varint(self: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return error.StructCodec;
            const b = self.buf[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) return result;
            shift += 7;
            if (shift >= 70) return error.StructCodec;
        }
    }
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return error.StructCodec;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }
    fn bytesField(self: *Reader) Error![]const u8 {
        const n = try self.varint();
        return self.take(@intCast(n));
    }
};

fn parseField(alloc: std.mem.Allocator, data: []const u8) Error!*FieldM {
    const f = try alloc.create(FieldM);
    f.* = .{};
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const num: u32 = @intCast(tag >> 3);
        switch (tag & 7) {
            0 => {
                const v = try r.varint();
                switch (num) {
                    3 => f.number = @intCast(v),
                    4 => f.repeated = v == 3,
                    5 => f.ftype = @intCast(v),
                    else => {},
                }
            },
            2 => {
                const v = try r.bytesField();
                switch (num) {
                    1 => f.name = v,
                    6 => f.type_name = v,
                    else => {},
                }
            },
            1 => _ = try r.take(8),
            5 => _ = try r.take(4),
            else => return error.StructCodec,
        }
    }
    return f;
}

fn parseMessage(alloc: std.mem.Allocator, prefix: []const u8, data: []const u8, fm: *FileM) Error!void {
    var name: []const u8 = "";
    var options: ?[]const u8 = null;
    var raw_fields: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const num: u32 = @intCast(tag >> 3);
        switch (tag & 7) {
            0 => _ = try r.varint(),
            2 => {
                const v = try r.bytesField();
                switch (num) {
                    1 => name = v,
                    2 => try raw_fields.append(alloc, v),
                    3 => try nested.append(alloc, v),
                    7 => options = v,
                    else => {},
                }
            },
            1 => _ = try r.take(8),
            5 => _ = try r.take(4),
            else => return error.StructCodec,
        }
    }
    const full_name = if (prefix.len == 0) name else try std.fmt.allocPrint(alloc, "{s}.{s}", .{ prefix, name });
    const model = try alloc.create(MsgM);
    model.* = .{ .full_name = full_name, .fields = std.AutoHashMap(u32, *FieldM).init(alloc) };
    if (options) |opts| {
        var ordr = Reader{ .buf = opts };
        while (ordr.pos < opts.len) {
            const tag = try ordr.varint();
            const num: u32 = @intCast(tag >> 3);
            switch (tag & 7) {
                0 => {
                    const v = try ordr.varint();
                    if (num == 7 and v != 0) model.map_entry = true;
                },
                2 => _ = try ordr.bytesField(),
                1 => _ = try ordr.take(8),
                5 => _ = try ordr.take(4),
                else => return error.StructCodec,
            }
        }
    }
    const key = try std.fmt.allocPrint(alloc, ".{s}", .{full_name});
    try fm.messages.put(key, model);
    for (raw_fields.items) |b| {
        const f = try parseField(alloc, b);
        try model.fields.put(f.number, f);
    }
    for (nested.items) |b| try parseMessage(alloc, full_name, b, fm);
}

fn parseDescriptorSet(alloc: std.mem.Allocator, data: []const u8) Error!*FileM {
    const fm = try alloc.create(FileM);
    fm.* = .{ .messages = std.StringHashMap(*MsgM).init(alloc) };
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const tag = try r.varint();
        const num: u32 = @intCast(tag >> 3);
        switch (tag & 7) {
            0 => _ = try r.varint(),
            2 => {
                const file_bytes = try r.bytesField();
                if (num == 1) {
                    var pkg: []const u8 = "";
                    var msgs: std.ArrayList([]const u8) = .empty;
                    var fr = Reader{ .buf = file_bytes };
                    while (fr.pos < file_bytes.len) {
                        const t2 = try fr.varint();
                        const n2: u32 = @intCast(t2 >> 3);
                        switch (t2 & 7) {
                            0 => _ = try fr.varint(),
                            2 => {
                                const v = try fr.bytesField();
                                if (n2 == 2) pkg = v else if (n2 == 4) try msgs.append(alloc, v);
                            },
                            1 => _ = try fr.take(8),
                            5 => _ = try fr.take(4),
                            else => return error.StructCodec,
                        }
                    }
                    for (msgs.items) |m| try parseMessage(alloc, pkg, m, fm);
                }
            },
            1 => _ = try r.take(8),
            5 => _ = try r.take(4),
            else => return error.StructCodec,
        }
    }
    return fm;
}

fn zigzagDecode(v: u64) i64 {
    return @as(i64, @bitCast(v >> 1)) ^ -@as(i64, @intCast(v & 1));
}

fn u32At(b: []const u8, off: usize) Error!u64 {
    if (off + 4 > b.len) return error.StructCodec;
    return @as(u64, b[off]) | (@as(u64, b[off + 1]) << 8) | (@as(u64, b[off + 2]) << 16) | (@as(u64, b[off + 3]) << 24);
}

fn u64At(b: []const u8, off: usize) Error!u64 {
    if (off + 8 > b.len) return error.StructCodec;
    var v: u64 = 0;
    for (0..8) |i| v |= @as(u64, b[off + i]) << @intCast(8 * i);
    return v;
}

fn asU64(v: Value) u64 {
    return switch (v) {
        .int => |x| @bitCast(x),
        .boolean => |b| if (b) @as(u64, 1) else @as(u64, 0),
        .float => |d| @bitCast(@as(i64, @intFromFloat(d))),
        else => 0,
    };
}

fn decodeValueS(alloc: std.mem.Allocator, f: *FieldM, wire: u32, raw: Value, fm: *FileM) Error!Value {
    switch (wire) {
        0 => {
            const v: u64 = @bitCast(raw.int);
            switch (f.ftype) {
                t_bool => return Value{ .boolean = v != 0 },
                t_sint32, t_sint64 => return Value{ .int = zigzagDecode(v) },
                t_int32, t_enum => return Value{ .int = @as(i32, @bitCast(@as(u32, @truncate(v)))) },
                t_uint32 => return Value{ .int = @bitCast(v & 0xffffffff) },
                t_int64 => return Value{ .int = @bitCast(v) },
                else => return Value{ .int = @bitCast(v) },
            }
        },
        1 => {
            const b = raw.bytes;
            const u = try u64At(b, 0);
            if (f.ftype == t_double) return Value{ .float = @bitCast(u) };
            return Value{ .int = @bitCast(u) };
        },
        5 => {
            const b = raw.bytes;
            const u = try u32At(b, 0);
            if (f.ftype == t_float) return Value{ .float = @as(f32, @bitCast(@as(u32, @truncate(u)))) };
            if (f.ftype == t_sfixed32) return Value{ .int = @as(i32, @bitCast(@as(u32, @truncate(u)))) };
            return Value{ .int = @bitCast(u) };
        },
        else => {
            const b = raw.bytes;
            switch (f.ftype) {
                t_string => return Value{ .string = b },
                t_message => {
                    const nested = try alloc.create(Generic);
                    nested.* = Generic.init(alloc);
                    try decodeGenericS(alloc, fm.messages.get(f.type_name).?, b, fm, nested);
                    return Value{ .message = nested };
                },
                else => return Value{ .bytes = b },
            }
        },
    }
}

fn decodePacked(alloc: std.mem.Allocator, f: *FieldM, data: []const u8, fm: *FileM, out: *std.ArrayList(Value)) Error!void {
    if (f.ftype == t_double or f.ftype == t_fixed64 or f.ftype == t_sfixed64) {
        var i: usize = 0;
        while (i + 8 <= data.len) : (i += 8) {
            try out.append(alloc, try decodeValueS(alloc, f, 1, Value{ .bytes = data[i..][0..8] }, fm));
        }
    } else if (f.ftype == t_float or f.ftype == t_fixed32 or f.ftype == t_sfixed32) {
        var i: usize = 0;
        while (i + 4 <= data.len) : (i += 4) {
            try out.append(alloc, try decodeValueS(alloc, f, 5, Value{ .bytes = data[i..][0..4] }, fm));
        }
    } else {
        var r = Reader{ .buf = data };
        while (r.pos < data.len) {
            const v = try r.varint();
            try out.append(alloc, try decodeValueS(alloc, f, 0, Value{ .int = @bitCast(v) }, fm));
        }
    }
}

fn decodeGenericS(alloc: std.mem.Allocator, model: *MsgM, data: []const u8, fm: *FileM, msg: *Generic) Error!void {
    var r = Reader{ .buf = data };
    while (r.pos < data.len) {
        const start = r.pos;
        const tag = try r.varint();
        const num: u32 = @intCast(tag >> 3);
        const wire: u32 = @intCast(tag & 7);
        var raw: Value = Value{ .int = 0 };
        switch (wire) {
            0 => raw = Value{ .int = @bitCast(try r.varint()) },
            2 => raw = Value{ .bytes = try r.bytesField() },
            1 => raw = Value{ .bytes = try r.take(8) },
            5 => raw = Value{ .bytes = try r.take(4) },
            else => return error.StructCodec,
        }
        const chunk = data[start..r.pos];
        const f = model.fields.get(num) orelse {
            try msg.unknown.append(alloc, try alloc.dupe(u8, chunk));
            continue;
        };
        if (f.repeated and wire == 2 and f.ftype != t_string and f.ftype != t_bytes and f.ftype != t_message and f.ftype != t_group) {
            var vs: std.ArrayList(Value) = .empty;
            try decodePacked(alloc, f, raw.bytes, fm, &vs);
            for (vs.items) |v| try msg.add(alloc, num, v);
            continue;
        }
        try msg.add(alloc, num, try decodeValueS(alloc, f, wire, raw, fm));
    }
}

fn encodeVarint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: u64) !void {
    var v = value;
    while ((v & ~@as(u64, 0x7f)) != 0) {
        try out.append(alloc, @intCast((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try out.append(alloc, @intCast(v & 0xff));
}

fn wireType(t: i32) i32 {
    return switch (t) {
        t_int64, t_uint64, t_int32, t_bool, t_uint32, t_enum, t_sint32, t_sint64 => 0,
        t_fixed64, t_sfixed64, t_double => 1,
        t_string, t_message, t_bytes, t_group => 2,
        else => 5,
    };
}

fn append32(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u64) !void {
    for (0..4) |i| try out.append(alloc, @intCast((v >> @intCast(8 * i)) & 0xff));
}
fn append64(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u64) !void {
    for (0..8) |i| try out.append(alloc, @intCast((v >> @intCast(8 * i)) & 0xff));
}

fn encodeValue(alloc: std.mem.Allocator, out: *std.ArrayList(u8), f: *FieldM, v: Value, fm: *FileM) Error!void {
    const wire = wireType(f.ftype);
    try encodeVarint(out, alloc, @as(u64, @intCast(f.number << 3 | @as(u32, @intCast(wire)))));
    switch (wire) {
        0 => {
            switch (f.ftype) {
                t_sint32 => {
                    const sv: i32 = @bitCast(@as(u32, @truncate(asU64(v))));
                    try encodeVarint(out, alloc, @as(u32, @bitCast((sv << 1) ^ (sv >> 31))));
                },
                t_sint64 => {
                    const sv: i64 = @bitCast(asU64(v));
                    try encodeVarint(out, alloc, @bitCast((sv << 1) ^ (sv >> 63)));
                },
                t_bool => try encodeVarint(out, alloc, if (asU64(v) != 0) 1 else 0),
                else => try encodeVarint(out, alloc, asU64(v)),
            }
        },
        1 => {
            if (f.ftype == t_double) {
                try append64(out, alloc, @bitCast(v.float));
            } else try append64(out, alloc, asU64(v));
        },
        5 => {
            if (f.ftype == t_float) {
                try append32(out, alloc, @as(u32, @bitCast(@as(f32, @floatCast(v.float)))));
            } else try append32(out, alloc, asU64(v) & 0xffffffff);
        },
        else => {
            var data: []const u8 = &[_]u8{};
            var owned: ?[]u8 = null;
            switch (f.ftype) {
                t_string => data = v.string,
                t_message => {
                    owned = try encodeGeneric(alloc, fm.messages.get(f.type_name).?, v.message, fm);
                    data = owned.?;
                },
                else => data = v.bytes,
            }
            try encodeVarint(out, alloc, data.len);
            try out.appendSlice(alloc, data);
        },
    }
}

fn encodeGeneric(alloc: std.mem.Allocator, model: *MsgM, msg: *Generic, fm: *FileM) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var nums: std.ArrayList(u32) = .empty;
    var kit = msg.values.keyIterator();
    while (kit.next()) |k| try nums.append(alloc, k.*);
    std.mem.sort(u32, nums.items, {}, std.sort.asc(u32));
    for (nums.items) |num| {
        const f = model.fields.get(num) orelse return error.StructCodec;
        const values = msg.getAll(num);
        if (f.repeated) {
            for (values) |v| try encodeValue(alloc, &out, f, v, fm);
        } else if (values.len > 0) {
            try encodeValue(alloc, &out, f, values[0], fm);
        }
    }
    for (msg.unknown.items) |c| try out.appendSlice(alloc, c);
    return out.toOwnedSlice(alloc);
}

fn fingerprint(full_name: []const u8) u64 {
    var h: u64 = 2166136261;
    for (full_name) |b| h = ((h ^ b) * 16777619) & 0xffffffff;
    return h;
}

fn isFixed32(f: *FieldM) bool {
    return f.ftype == t_float or f.ftype == t_fixed32 or f.ftype == t_sfixed32;
}
fn slotSize(f: *FieldM) usize {
    return if (isFixed32(f)) 4 else 8;
}

fn bytesOf(v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .bytes => |b| b,
        else => error.StructCodec,
    };
}

fn nonzero(f: *FieldM, v: Value) bool {
    return switch (f.ftype) {
        t_string => v.string.len > 0,
        t_bytes => v.bytes.len > 0,
        t_message => v == .message,
        t_bool => asU64(v) != 0,
        t_float, t_double => v.float != 0.0,
        else => asU64(v) != 0,
    };
}

fn sortedFields(alloc: std.mem.Allocator, model: *MsgM) ![]*FieldM {
    var nums: std.ArrayList(u32) = .empty;
    var kit = model.fields.keyIterator();
    while (kit.next()) |k| try nums.append(alloc, k.*);
    std.mem.sort(u32, nums.items, {}, std.sort.asc(u32));
    var out: std.ArrayList(*FieldM) = .empty;
    for (nums.items) |n| try out.append(alloc, model.fields.get(n).?);
    return out.toOwnedSlice(alloc);
}

fn mapModel(f: *FieldM, fm: *FileM) ?*MsgM {
    if (f.ftype != t_message or !f.repeated) return null;
    const m = fm.messages.get(f.type_name) orelse return null;
    return if (m.map_entry) m else null;
}

fn defaultValue(f: *FieldM, alloc: std.mem.Allocator) !Value {
    return switch (f.ftype) {
        t_string => Value{ .string = "" },
        t_bytes => Value{ .bytes = &[_]u8{} },
        t_bool => Value{ .boolean = false },
        t_float, t_double => Value{ .float = 0.0 },
        t_message => blk: {
            const g = try alloc.create(Generic);
            g.* = Generic.init(alloc);
            break :blk Value{ .message = g };
        },
        else => Value{ .int = 0 },
    };
}

fn keyCmp(kf: *FieldM, a: Value, b: Value) i32 {
    if (kf.ftype == t_string) {
        return switch (std.mem.order(u8, a.string, b.string)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }
    if (kf.ftype == t_bool or kf.ftype == t_uint32 or kf.ftype == t_uint64 or kf.ftype == t_fixed32 or kf.ftype == t_fixed64) {
        const av = asU64(a);
        const bv = asU64(b);
        return if (av < bv) -1 else if (av > bv) 1 else 0;
    }
    const av: i64 = @bitCast(asU64(a));
    const bv: i64 = @bitCast(asU64(b));
    return if (av < bv) -1 else if (av > bv) 1 else 0;
}

const Entry = struct { key: Value, val: Value };

fn mapEntries(alloc: std.mem.Allocator, values: []const Value, em: *MsgM) Error![]Entry {
    const kf = em.fields.get(1).?;
    const vf = em.fields.get(2).?;
    var out: std.ArrayList(Entry) = .empty;
    for (values) |e| {
        const entry = e.message;
        const key = entry.get(1) orelse return error.StructCodec;
        const v = entry.get(2) orelse try defaultValue(vf, alloc);
        try out.append(alloc, .{ .key = key, .val = v });
    }
    std.mem.sort(Entry, out.items, kf, struct {
        fn lt(k: *FieldM, x: Entry, y: Entry) bool {
            return keyCmp(k, x.key, y.key) < 0;
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

fn valueSize(alloc: std.mem.Allocator, f: *FieldM, v: Value, fm: *FileM) Error!usize {
    switch (f.ftype) {
        t_string, t_bytes => return (try bytesOf(v)).len,
        t_message => {
            const enc = try encodeStruct(alloc, fm.messages.get(f.type_name).?, v.message, fm);
            return enc.len;
        },
        else => return if (isFixed32(f)) 4 else 8,
    }
}

fn fieldPresent(f: *FieldM, msg: *Generic, fm: *FileM) bool {
    const values = msg.getAll(f.number);
    if (mapModel(f, fm) != null or f.repeated) return values.len > 0;
    return values.len > 0 and nonzero(f, values[0]);
}

fn structSize(alloc: std.mem.Allocator, model: *MsgM, msg: *Generic, fm: *FileM) Error!usize {
    const fields = try sortedFields(alloc, model);
    const words = @max(1, (fields.len + 31) / 32);
    var size: usize = 12 + 4 * words;
    for (fields) |f| size += slotSize(f);
    for (fields) |f| {
        const values = msg.getAll(f.number);
        if (mapModel(f, fm)) |em| {
            const kf = em.fields.get(1).?;
            const vf = em.fields.get(2).?;
            for (try mapEntries(alloc, values, em)) |e| {
                size += 8 + try valueSize(alloc, kf, e.key, fm) + try valueSize(alloc, vf, e.val, fm);
            }
        } else if (f.repeated) {
            if (values.len > 0) {
                if (f.ftype == t_string or f.ftype == t_bytes or f.ftype == t_message) size += 8 * values.len;
                for (values) |v| size += try valueSize(alloc, f, v, fm);
            }
        } else if ((f.ftype == t_string or f.ftype == t_bytes or f.ftype == t_message) and fieldPresent(f, msg, fm)) {
            size += try valueSize(alloc, f, values[0], fm);
        }
    }
    for (msg.unknown.items) |c| size += c.len;
    return size;
}

fn putU32(buf: []u8, off: usize, v: u64) void {
    for (0..4) |i| buf[off + i] = @intCast((v >> @intCast(8 * i)) & 0xff);
}
fn putU64(buf: []u8, off: usize, v: u64) void {
    for (0..8) |i| buf[off + i] = @intCast((v >> @intCast(8 * i)) & 0xff);
}

fn writeScalar(buf: []u8, off: usize, f: *FieldM, v: Value) void {
    switch (f.ftype) {
        t_float => putU32(buf, off, @as(u32, @bitCast(@as(f32, @floatCast(v.float))))),
        t_fixed32 => putU32(buf, off, asU64(v)),
        t_sfixed32 => putU32(buf, off, asU64(v) & 0xffffffff),
        t_double => putU64(buf, off, @bitCast(v.float)),
        t_fixed64, t_sfixed64 => putU64(buf, off, asU64(v)),
        t_bool => buf[off] = if (asU64(v) != 0) 1 else 0,
        else => putU64(buf, off, asU64(v)),
    }
}

fn writeValue(alloc: std.mem.Allocator, buf: []u8, off: usize, f: *FieldM, v: Value, fm: *FileM) Error!void {
    switch (f.ftype) {
        t_string, t_bytes => {
            const b = try bytesOf(v);
            @memcpy(buf[off..][0..b.len], b);
        },
        t_message => {
            const enc = try encodeStruct(alloc, fm.messages.get(f.type_name).?, v.message, fm);
            @memcpy(buf[off..][0..enc.len], enc);
        },
        else => writeScalar(buf, off, f, v),
    }
}

fn encodeStruct(alloc: std.mem.Allocator, model: *MsgM, msg: *Generic, fm: *FileM) Error![]u8 {
    const fields = try sortedFields(alloc, model);
    const words = @max(1, (fields.len + 31) / 32);
    const header = 12 + 4 * words;
    var offsets: std.ArrayList(usize) = .empty;
    var cursor: usize = header;
    for (fields) |f| {
        try offsets.append(alloc, cursor);
        cursor += slotSize(f);
    }
    const fixed_end = cursor;
    const buf = try alloc.alloc(u8, try structSize(alloc, model, msg, fm));
    @memset(buf, 0);
    @memcpy(buf[0..4], "DCS1");
    putU32(buf, 4, buf.len);
    putU32(buf, 8, fingerprint(model.full_name));
    for (fields, 0..) |f, i| {
        if (fieldPresent(f, msg, fm)) {
            const at = 12 + 4 * (i / 32);
            putU32(buf, at, (try u32At(buf, at)) | (@as(u64, 1) << @intCast(i % 32)));
        }
    }
    var vp = fixed_end;
    for (fields, 0..) |f, i| {
        const off = offsets.items[i];
        const values = msg.getAll(f.number);
        if (mapModel(f, fm)) |em| {
            if (values.len > 0) {
                const kf = em.fields.get(1).?;
                const vf = em.fields.get(2).?;
                putU32(buf, off, vp);
                putU32(buf, off + 4, values.len);
                for (try mapEntries(alloc, values, em)) |e| {
                    const klen = try valueSize(alloc, kf, e.key, fm);
                    const vlen = try valueSize(alloc, vf, e.val, fm);
                    putU32(buf, vp, klen);
                    putU32(buf, vp + 4, vlen);
                    vp += 8;
                    try writeValue(alloc, buf, vp, kf, e.key, fm);
                    vp += klen;
                    try writeValue(alloc, buf, vp, vf, e.val, fm);
                    vp += vlen;
                }
            }
        } else if (f.repeated) {
            if (values.len > 0) {
                putU32(buf, off, vp);
                putU32(buf, off + 4, values.len);
                if (f.ftype == t_string or f.ftype == t_bytes or f.ftype == t_message) {
                    var doff = vp + 8 * values.len;
                    for (values) |v| {
                        putU32(buf, vp, doff);
                        putU32(buf, vp + 4, try valueSize(alloc, f, v, fm));
                        doff += try valueSize(alloc, f, v, fm);
                        vp += 8;
                    }
                    for (values) |v| {
                        try writeValue(alloc, buf, vp, f, v, fm);
                        vp += try valueSize(alloc, f, v, fm);
                    }
                } else {
                    for (values) |v| {
                        writeScalar(buf, vp, f, v);
                        vp += slotSize(f);
                    }
                }
            }
        } else if (f.ftype == t_string or f.ftype == t_bytes or f.ftype == t_message) {
            if (fieldPresent(f, msg, fm)) {
                putU32(buf, off, vp);
                putU32(buf, off + 4, try valueSize(alloc, f, values[0], fm));
                try writeValue(alloc, buf, vp, f, values[0], fm);
                vp += try valueSize(alloc, f, values[0], fm);
            }
        } else if (fieldPresent(f, msg, fm)) {
            writeScalar(buf, off, f, values[0]);
        }
    }
    for (msg.unknown.items) |chunk| {
        @memcpy(buf[vp..][0..chunk.len], chunk);
        vp += chunk.len;
    }
    return buf;
}

fn readScalar(data: []const u8, off: usize, f: *FieldM) Error!Value {
    switch (f.ftype) {
        t_float => return Value{ .float = @as(f32, @bitCast(@as(u32, @truncate(try u32At(data, off))))) },
        t_fixed32 => return Value{ .int = @bitCast(try u32At(data, off)) },
        t_sfixed32 => return Value{ .int = @as(i32, @bitCast(@as(u32, @truncate(try u32At(data, off))))) },
        t_double => return Value{ .float = @bitCast(try u64At(data, off)) },
        t_fixed64, t_sfixed64 => return Value{ .int = @bitCast(try u64At(data, off)) },
        t_bool => {
            if (off >= data.len) return error.StructCodec;
            return Value{ .boolean = data[off] != 0 };
        },
        t_enum, t_int32, t_sint32 => return Value{ .int = @as(i32, @bitCast(@as(u32, @truncate(try u64At(data, off))))) },
        t_int64, t_sint64 => return Value{ .int = @bitCast(try u64At(data, off)) },
        t_uint32 => return Value{ .int = @bitCast((try u64At(data, off)) & 0xffffffff) },
        else => return Value{ .int = @bitCast(try u64At(data, off)) },
    }
}

fn readValue(alloc: std.mem.Allocator, data: []const u8, off: usize, len: usize, f: *FieldM, fm: *FileM) Error!Value {
    if (off + len > data.len) return error.StructCodec;
    switch (f.ftype) {
        t_string => return Value{ .string = data[off..][0..len] },
        t_bytes => return Value{ .bytes = data[off..][0..len] },
        t_message => {
            if (len == 0) {
                const g = try alloc.create(Generic);
                g.* = Generic.init(alloc);
                return Value{ .message = g };
            }
            const nested = try alloc.create(Generic);
            nested.* = Generic.init(alloc);
            try decodeStruct(alloc, fm.messages.get(f.type_name).?, data[off..][0..len], fm, nested);
            return Value{ .message = nested };
        },
        else => return readScalar(data, off, f),
    }
}

fn decodeStruct(alloc: std.mem.Allocator, model: *MsgM, data: []const u8, fm: *FileM, msg: *Generic) Error!void {
    const fields = try sortedFields(alloc, model);
    const words = @max(1, (fields.len + 31) / 32);
    const header = 12 + 4 * words;
    if (data.len < header or !std.mem.eql(u8, data[0..4], "DCS1")) return error.StructCodec;
    if ((try u32At(data, 8)) != fingerprint(model.full_name)) return error.StructCodec;
    if ((try u32At(data, 4)) != data.len) return error.StructCodec;
    var offsets: std.ArrayList(usize) = .empty;
    var cursor: usize = header;
    for (fields) |f| {
        try offsets.append(alloc, cursor);
        cursor += slotSize(f);
    }
    var vend = cursor;
    for (fields, 0..) |f, i| {
        if (((try u32At(data, 12 + 4 * (i / 32))) & (@as(u64, 1) << @intCast(i % 32))) == 0) continue;
        const off = offsets.items[i];
        if (mapModel(f, fm)) |em| {
            const kf = em.fields.get(1).?;
            const vf = em.fields.get(2).?;
            const base: usize = @intCast(try u32At(data, off));
            const n: usize = @intCast(try u32At(data, off + 4));
            var p = base;
            for (0..n) |_| {
                const kl: usize = @intCast(try u32At(data, p));
                const vl: usize = @intCast(try u32At(data, p + 4));
                p += 8;
                const key = try readValue(alloc, data, p, kl, kf, fm);
                const v = try readValue(alloc, data, p + kl, vl, vf, fm);
                const entry = try alloc.create(Generic);
                entry.* = Generic.init(alloc);
                try entry.set(alloc, 1, key);
                try entry.set(alloc, 2, v);
                try msg.add(alloc, f.number, Value{ .message = entry });
                p += kl + vl;
            }
            vend = @max(vend, p);
        } else if (f.repeated) {
            const base: usize = @intCast(try u32At(data, off));
            const n: usize = @intCast(try u32At(data, off + 4));
            if (f.ftype == t_string or f.ftype == t_bytes or f.ftype == t_message) {
                for (0..n) |j| {
                    const eo: usize = @intCast(try u32At(data, base + 8 * j));
                    const el: usize = @intCast(try u32At(data, base + 8 * j + 4));
                    if (el > 0 or f.ftype != t_message) {
                        try msg.add(alloc, f.number, try readValue(alloc, data, eo, el, f, fm));
                    }
                    vend = @max(vend, eo + el);
                }
            } else {
                for (0..n) |j| {
                    try msg.add(alloc, f.number, try readScalar(data, base + j * slotSize(f), f));
                }
                vend = @max(vend, base + n * slotSize(f));
            }
        } else if (f.ftype == t_string or f.ftype == t_bytes or f.ftype == t_message) {
            const base: usize = @intCast(try u32At(data, off));
            const len: usize = @intCast(try u32At(data, off + 4));
            try msg.add(alloc, f.number, try readValue(alloc, data, base, len, f, fm));
            vend = @max(vend, base + len);
        } else {
            try msg.add(alloc, f.number, try readScalar(data, off, f));
        }
    }
    if (vend < data.len) try msg.unknown.append(alloc, try alloc.dupe(u8, data[vend..]));
}

/// Transcode protobuf <-> struct bytes for `type_name` under
/// the FileDescriptorSet bytes `descriptor`.
pub fn transcode(alloc: std.mem.Allocator, descriptor: []const u8, type_name: []const u8, data: []const u8, encode: bool) Error![]u8 {
    const fm = try parseDescriptorSet(alloc, descriptor);
    const model = fm.messages.get(type_name) orelse fm.messages.get(try std.fmt.allocPrint(alloc, ".{s}", .{type_name})) orelse return error.StructCodec;
    if (encode) {
        var msg = Generic.init(alloc);
        try decodeGenericS(alloc, model, data, fm, &msg);
        return encodeStruct(alloc, model, &msg, fm);
    }
    var msg = Generic.init(alloc);
    try decodeStruct(alloc, model, data, fm, &msg);
    return encodeGeneric(alloc, model, &msg, fm);
}
GRPC_RUNTIME_EOF
)
