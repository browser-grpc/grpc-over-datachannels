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
const wire = @import("wire.zig");

/// A gRPC status (code + message), carried as a value: Zig has no
/// exceptions, so fallible runtime calls return Status (codeOk means
/// success) or a result union embedding one. Mirrors StatusException
/// in the other grpcdc runtimes.
pub const Status = struct {
    code: i32 = wire.codeOk,
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

/// Frame codec for gRPC over WebRTC DataChannels (wire protocol in
/// ../SPEC.md). Frame, status, channel and server semantics mirror the
/// other grpcdc runtimes; the tables in wire.zig are stamped by the
/// Racket metaprogram.
pub const Codec = struct {
    pub const header_len: usize = 9;
    pub const max_data_payload: usize = 16 * 1024 * 1024;

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

    pub fn statusFrame(alloc: std.mem.Allocator, frame_type: u8, stream_id: u32, st: Status) EncodeResult {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        aw.writer.print("{{\"code\":{d},\"message\":", .{st.code}) catch return oom();
        writeJsonString(&aw.writer, st.message) catch return oom();
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
        return Status.init(@intCast(code_val.integer), owned);
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

    pub fn send(self: Transport, data: []const u8) !void {
        return self.send_fn(self.ctx, data);
    }

    pub fn recv(self: Transport, alloc: std.mem.Allocator) !?[]u8 {
        return self.recv_fn(self.ctx, alloc);
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
        }
        self.* = undefined;
    }
};

/// Receiving queue of one stream; closed after a terminal event.
/// put transfers ownership of the event's allocations; get transfers
/// them to the caller (free with event.deinit).
pub const StreamInput = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: std.ArrayList(StreamEvent) = .empty,
    closed: bool = false,

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
            self.cond.wait(&self.mutex);
        }
        return self.queue.orderedRemove(0);
    }

    pub fn deinit(self: *StreamInput, alloc: std.mem.Allocator) void {
        for (self.queue.items) |*ev| ev.deinit(alloc);
        self.queue.deinit(alloc);
    }
};

/// Per-call context: metadata sent in HEADERS.
pub const CallContext = struct {
    metadata: Metadata,
};

/// Sends response payloads of one inbound call.
pub const ResponseSink = struct {
    endpoint: *Endpoint,
    stream_id: u32,

    pub fn send(self: ResponseSink, payload: []const u8) void {
        const frame = switch (Codec.encodeFrame(self.endpoint.alloc, wire.frameData, self.stream_id, payload)) {
            .bytes => |b| b,
            .status => return,
        };
        defer self.endpoint.alloc.free(frame);
        self.endpoint.sendFrame(frame);
    }

    pub fn sendHeaders(self: ResponseSink) void {
        const frame = switch (Codec.headersFrame(self.endpoint.alloc, self.stream_id, null, null)) {
            .bytes => |b| b,
            .status => return,
        };
        defer self.endpoint.alloc.free(frame);
        self.endpoint.sendFrame(frame);
    }

    pub fn sendTrailers(self: ResponseSink, st: Status) void {
        const frame = switch (Codec.statusFrame(self.endpoint.alloc, wire.frameTrailers, self.stream_id, st)) {
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
    read_thread: ?std.Thread = null,
    active_calls: usize = 0,
    calls_mutex: std.Thread.Mutex = .{},
    calls_cond: std.Thread.Condition = .{},

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

    /// Start the read loop (idempotent).
    pub fn start(self: *Endpoint) void {
        if (self.started) return;
        self.started = true;
        self.read_thread = std.Thread.spawn(.{}, readLoop, .{self}) catch null;
    }

    pub fn deinit(self: *Endpoint) void {
        self.close();
        if (self.read_thread) |t| t.join();
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

    fn stream(self: *Endpoint, id: u32) ?*StreamInput {
        self.streams_mutex.lock();
        defer self.streams_mutex.unlock();
        return self.streams.get(id);
    }

    fn registerStream(self: *Endpoint, id: u32, input: *StreamInput) void {
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
        const sink = ResponseSink{ .endpoint = self, .stream_id = args.stream_id };
        sink.sendHeaders();
        const call_ctx = CallContext{ .metadata = headers.metadata };
        const st = args.dispatcher(args.ctx, call_ctx, headers, args.input, sink);
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

    /// Receive the next response payload. End means the call
    /// completed OK; status reports the trailers status.
    pub fn recvRaw(self: *ClientStream) status_mod.RecvResult([]u8) {
        const alloc = self.endpoint.alloc;
        while (true) {
            var event = self.input.get() orelse
                return .{ .status = Status.init(wire.codeUnavailable, "data channel closed") };
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
                    const st = event.status orelse Status.ok();
                    event.status = null;
                    event.deinit(alloc);
                    if (st.isOk()) return .end;
                    return .{ .status = st };
                },
                .rst => {
                    const st = event.status orelse Status.init(wire.codeUnavailable, "stream reset");
                    event.status = null;
                    event.deinit(alloc);
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
                resp.unmarshalDc(self.endpoint.alloc, payload);
                return .message;
            },
            .end => return .end,
            .status => |st| return .{ .status = st },
        }
    }

    pub fn deinit(self: *ClientStream) void {
        if (self.headers) |*h| Codec.freeHeaders(self.endpoint.alloc, h);
        self.endpoint.closeStream(self.stream_id);
    }
};

pub const StreamResult = status_mod.CallResult(ClientStream);

/// Channel: the client side of one Endpoint.
pub const Channel = struct {
    endpoint: *Endpoint,
    owns_endpoint: bool,

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

    fn open(self: *Channel, path: []const u8, metadata: ?*const Metadata) StreamResult {
        const alloc = self.endpoint.alloc;
        const opened = self.endpoint.openStream();
        const frame = switch (Codec.headersFrame(alloc, opened.id, path, metadata)) {
            .bytes => |b| b,
            .status => |st| {
                self.endpoint.closeStream(opened.id);
                return .{ .status = st };
            },
        };
        defer alloc.free(frame);
        self.endpoint.sendFrame(frame);
        return .{ .ok = .{ .stream_id = opened.id, .input = opened.input, .endpoint = self.endpoint } };
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
            const payload = req.marshalDc(alloc);
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
    pub fn unary(self: *Channel, path: []const u8, req: anytype, resp: anytype, metadata: ?*const Metadata) Status {
        var stream = switch (self.open(path, metadata)) {
            .ok => |s| s,
            .status => |st| return st,
        };
        defer stream.deinit();
        const alloc = self.endpoint.alloc;
        const payload = req.marshalDc(alloc);
        defer alloc.free(payload);
        const st = self.sendMessage(&stream, payload);
        if (!st.isOk()) return st;
        self.halfClose(&stream);
        return self.collectOne(&stream, resp, "unary");
    }

    /// Start a server-streaming call.
    pub fn serverStream(self: *Channel, path: []const u8, req: anytype, metadata: ?*const Metadata) StreamResult {
        var stream = switch (self.open(path, metadata)) {
            .ok => |s| s,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.endpoint.alloc;
        const payload = req.marshalDc(alloc);
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
    pub fn clientStreamCall(self: *Channel, path: []const u8, reqs: anytype, resp: anytype, metadata: ?*const Metadata) Status {
        var stream = switch (self.open(path, metadata)) {
            .ok => |s| s,
            .status => |st| return st,
        };
        defer stream.deinit();
        const st = self.sendAll(&stream, reqs);
        if (!st.isOk()) return st;
        return self.collectOne(&stream, resp, "client-streaming");
    }

    /// Start a bidi call with all requests sent up front.
    pub fn bidi(self: *Channel, path: []const u8, reqs: anytype, metadata: ?*const Metadata) StreamResult {
        var stream = switch (self.open(path, metadata)) {
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
                req.unmarshalDc(self.alloc, payload);
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

    pub fn send(self: Sink, payload: []const u8) void {
        self.sink.send(payload);
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
        var reqs = RequestStream{ .input = input, .alloc = self.alloc };
        return method.handler(method.ctx, &mutable_ctx, &reqs, .{ .sink = sink });
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

    pub fn unary(self: *DynamicClient, service_name: []const u8, method_name: []const u8, req: *GenericMessage, metadata: ?*const transport_mod.Metadata) CallResult(*GenericMessage) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.channel.endpoint.alloc;
        var bound_req = BoundMessage{ .model = m.input.?, .file = self.model, .generic = req };
        var bound_resp = BoundMessage{ .model = m.output.?, .file = self.model, .generic = newGeneric(alloc, m.output.?) };
        const st = self.channel.unary(m.path, &bound_req, &bound_resp, metadata);
        if (!st.isOk()) return .{ .status = st };
        return .{ .ok = bound_resp.generic };
    }

    pub fn serverStream(self: *DynamicClient, service_name: []const u8, method_name: []const u8, req: *GenericMessage, metadata: ?*const transport_mod.Metadata) CallResult(DynamicStream) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        var bound_req = BoundMessage{ .model = m.input.?, .file = self.model, .generic = req };
        switch (self.channel.serverStream(m.path, &bound_req, metadata)) {
            .ok => |stream| return .{ .ok = .{ .stream = stream, .output = m.output.?, .file = self.model } },
            .status => |st| return .{ .status = st },
        }
    }

    pub fn clientStream(self: *DynamicClient, service_name: []const u8, method_name: []const u8, reqs: []const *GenericMessage, metadata: ?*const transport_mod.Metadata) CallResult(*GenericMessage) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.channel.endpoint.alloc;
        var bound = alloc.alloc(BoundMessage, reqs.len) catch return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
        for (reqs, 0..) |r, i| bound[i] = .{ .model = m.input.?, .file = self.model, .generic = r };
        var bound_resp = BoundMessage{ .model = m.output.?, .file = self.model, .generic = newGeneric(alloc, m.output.?) };
        const st = self.channel.clientStreamCall(m.path, bound, &bound_resp, metadata);
        if (!st.isOk()) return .{ .status = st };
        return .{ .ok = bound_resp.generic };
    }

    pub fn bidi(self: *DynamicClient, service_name: []const u8, method_name: []const u8, reqs: []const *GenericMessage, metadata: ?*const transport_mod.Metadata) CallResult(DynamicStream) {
        const m = switch (self.method(service_name, method_name)) {
            .ok => |v| v,
            .status => |st| return .{ .status = st },
        };
        const alloc = self.channel.endpoint.alloc;
        var bound = alloc.alloc(BoundMessage, reqs.len) catch return .{ .status = Status.init(wire.codeResourceExhausted, "out of memory") };
        for (reqs, 0..) |r, i| bound[i] = .{ .model = m.input.?, .file = self.model, .generic = r };
        switch (self.channel.bidi(m.path, bound, metadata)) {
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
                    self.sink.send(bytes);
                    return Status.ok();
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

(define zig-root-body
#<<GRPC_RUNTIME_EOF
/// grpc-over-DataChannels runtime for Zig (stdlib only, no external
/// packages). Wire tables in wire.zig are stamped by the Racket
/// metaprogram; see ../SPEC.md.
pub const wire = @import("wire.zig");
pub const status = @import("status.zig");
pub const codec = @import("codec.zig");
pub const transport = @import("transport.zig");
pub const endpoint = @import("endpoint.zig");
pub const channel = @import("channel.zig");
pub const server = @import("server.zig");
pub const memory_transport = @import("memory_transport.zig");
pub const dynamic = @import("dynamic.zig");
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
   (cons "grpcdc/dynamic.zig" zig-dynamic-body)
   (cons "grpcdc/grpcdc.zig" zig-root-body)))
