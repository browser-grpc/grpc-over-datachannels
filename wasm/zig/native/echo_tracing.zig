//! Browser tracing entry point (native Zig/Wasm runtime):
//! runs a nested call chain entirely in the worker — client ->
//! front callee -> downstream service over in-memory transports —
//! with a recording span observer, and reports the spans as JSON
//! via on_result so the Playwright driver can assert the trace.
//! The inline pump is single-threaded, so client transports poll
//! their peer server endpoint on TryRecv (cooperative pumping).

const std = @import("std");
const grpcdc = @import("grpcdc");
const stubs = @import("echo_stub");

extern "env" fn on_result(ptr: [*]const u8, len: usize) void;
extern "env" fn on_error(ptr: [*]const u8, len: usize) void;

const alloc = std.heap.wasm_allocator;
const Status = stubs.Status;
const wire = grpcdc.wire;
const Endpoint = grpcdc.endpoint.Endpoint;

const Queue = struct {
    items: std.ArrayList([]u8) = .empty,
};

const QueueTransport = struct {
    inbox: *Queue,
    outbox: *Queue,
    poll_peer: ?*Endpoint = null,

    fn transport(self: *QueueTransport) grpcdc.endpoint.Transport {
        return .{
            .ctx = self,
            .send_fn = &sendFn,
            .recv_fn = &recvFn,
            .close_fn = &closeFn,
            .try_recv_fn = &tryRecvFn,
        };
    }

    fn sendFn(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *QueueTransport = @ptrCast(@alignCast(ctx));
        const copy = try alloc.dupe(u8, data);
        try self.outbox.items.append(alloc, copy);
    }

    fn recvFn(ctx: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
        const self: *QueueTransport = @ptrCast(@alignCast(ctx));
        while (true) {
            if (self.inbox.items.items.len > 0) {
                const msg = self.inbox.items.orderedRemove(0);
                const copy = try a.dupe(u8, msg);
                alloc.free(msg);
                return copy;
            }
            if (self.poll_peer) |peer| {
                peer.pollOnce();
            } else {
                return error.WouldBlock;
            }
        }
    }

    fn tryRecvFn(ctx: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
        const self: *QueueTransport = @ptrCast(@alignCast(ctx));
        if (self.poll_peer) |peer| peer.pollOnce();
        if (self.inbox.items.items.len == 0) return error.WouldBlock;
        const msg = self.inbox.items.orderedRemove(0);
        const copy = try a.dupe(u8, msg);
        alloc.free(msg);
        return copy;
    }

    fn closeFn(_: *anyopaque) void {}
};

const Start = struct {
    kind: [16]u8,
    kind_len: usize,
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: [16]u8,
    parent_len: usize,
};

const Recorder = struct {
    starts: [8]Start = undefined,
    start_count: usize = 0,
    end_count: usize = 0,

    fn onStart(ctx: *anyopaque, kind: []const u8, _method: []const u8, trace_id: []const u8, span_id: []const u8, parent_span_id: []const u8) void {
        _ = _method;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var s = Start{
            .kind = [_]u8{0} ** 16,
            .kind_len = kind.len,
            .trace_id = [_]u8{0} ** 32,
            .span_id = [_]u8{0} ** 16,
            .parent_span_id = [_]u8{0} ** 16,
            .parent_len = parent_span_id.len,
        };
        @memcpy(s.kind[0..kind.len], kind);
        @memcpy(&s.trace_id, trace_id[0..32]);
        @memcpy(&s.span_id, span_id[0..16]);
        if (parent_span_id.len != 0) @memcpy(&s.parent_span_id, parent_span_id[0..16]);
        self.starts[self.start_count] = s;
        self.start_count += 1;
    }

    fn onEnd(ctx: *anyopaque, _kind: []const u8, _method: []const u8, _trace_id: []const u8, _span_id: []const u8, _status: []const u8, _duration_ms: f64) void {
        _ = _kind;
        _ = _method;
        _ = _trace_id;
        _ = _span_id;
        _ = _status;
        _ = _duration_ms;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.end_count += 1;
    }
};

fn echoUnary(_: *anyopaque, ctx: *stubs.CallContext, req: *const stubs.EchoRequest, resp: *stubs.EchoResponse, a: std.mem.Allocator) Status {
    _ = ctx;
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(wire.codeInvalidArgument, "asked to fail");
    }
    resp.message = std.fmt.allocPrint(a, "echo: {s}", .{req.message}) catch return Status.init(wire.codeResourceExhausted, "out of memory");
    resp.index = 0;
    return Status.ok();
}

fn echoServerStream(_: *anyopaque, _: *stubs.CallContext, req: *const stubs.EchoRequest, stream: *stubs.EchoServerStreamServer) Status {
    var i: i32 = 0;
    while (i < req.count) : (i += 1) {
        var resp = stubs.EchoResponse{ .message = req.message, .index = i };
        const st = stream.send(&resp);
        if (!st.isOk()) return st;
    }
    return Status.ok();
}

fn echoClientStream(_: *anyopaque, _: *stubs.CallContext, stream: *stubs.EchoClientStreamServer) Status {
    var joined: std.ArrayList(u8) = .empty;
    var count: i32 = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |req| {
                if (count > 0) joined.append(stream.alloc, '+') catch return Status.init(wire.codeResourceExhausted, "out of memory");
                joined.appendSlice(stream.alloc, req.message) catch return Status.init(wire.codeResourceExhausted, "out of memory");
                count += 1;
            },
            .end => break,
            .status => |st| return st,
        }
    }
    stream.sendAndClose(.{ .message = joined.items, .index = count });
    return Status.ok();
}

fn echoBidi(_: *anyopaque, _: *stubs.CallContext, stream: *stubs.EchoBidiServer) Status {
    var index: i32 = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |req| {
                var resp = stubs.EchoResponse{ .message = req.message, .index = index };
                const st = stream.send(&resp);
                if (!st.isOk()) return st;
                index += 1;
            },
            .end => return Status.ok(),
            .status => |st| return st,
        }
    }
}

const Front = struct {
    downstream: *grpcdc.channel.Channel,
    seen_span: [16]u8 = [_]u8{0} ** 16,
};

fn frontUnary(ctx: *anyopaque, call_ctx: *stubs.CallContext, _req: *const stubs.EchoRequest, resp: *stubs.EchoResponse, _a: std.mem.Allocator) Status {
    _ = _req;
    _ = _a;
    const front: *Front = @ptrCast(@alignCast(ctx));
    if (call_ctx.trace_context) |tc| front.seen_span = tc.span_id;
    front.downstream.setTraceContext(call_ctx.trace_context);
    var client = stubs.EchoClient.init(front.downstream);
    var r = stubs.EchoRequest{ .message = "nested", .count = 0 };
    switch (client.unary(&r, null, null)) {
        .ok => |ok| {
            resp.* = ok;
            return Status.ok();
        },
        .status => |st| return st,
    }
}

fn failMsg(msg: []const u8) void {
    on_error(msg.ptr, msg.len);
}

export fn run_echo_tracing() void {
    var recorder = Recorder{};
    grpcdc.status.setTracer(.{ .ctx = &recorder, .on_start = Recorder.onStart, .on_end = Recorder.onEnd });
    defer grpcdc.status.setTracer(null);

    // Downstream service.
    var a2_in = Queue{};
    var b2_in = Queue{};
    var a2 = QueueTransport{ .inbox = &b2_in, .outbox = &a2_in };
    var b2 = QueueTransport{ .inbox = &a2_in, .outbox = &b2_in };
    var back = grpcdc.server.Server.init(alloc);
    var back_impl = stubs.EchoServer{
        .ctx = undefined,
        .unary_fn = echoUnary,
        .server_stream_fn = echoServerStream,
        .client_stream_fn = echoClientStream,
        .bidi_fn = echoBidi,
    };
    stubs.EchoGrpcDc.registerEchoServer(&back, &back_impl);
    const back_ep = back.serveTransport(b2.transport());
    a2.poll_peer = back_ep;
    var downstream_channel = grpcdc.channel.Channel.init(alloc, a2.transport());

    // Front callee.
    var front_state = Front{ .downstream = &downstream_channel };
    var front_impl = stubs.EchoServer{
        .ctx = &front_state,
        .unary_fn = frontUnary,
        .server_stream_fn = echoServerStream,
        .client_stream_fn = echoClientStream,
        .bidi_fn = echoBidi,
    };
    var a_in = Queue{};
    var b_in = Queue{};
    var a = QueueTransport{ .inbox = &b_in, .outbox = &a_in };
    var b = QueueTransport{ .inbox = &a_in, .outbox = &b_in };
    var front_server = grpcdc.server.Server.init(alloc);
    stubs.EchoGrpcDc.registerEchoServer(&front_server, &front_impl);
    const front_ep = front_server.serveTransport(b.transport());
    a.poll_peer = front_ep;
    var channel = grpcdc.channel.Channel.init(alloc, a.transport());
    var client = stubs.EchoClient.init(&channel);

    var req = stubs.EchoRequest{ .message = "hello", .count = 0 };
    const resp = switch (client.unary(&req, null, null)) {
        .ok => |ok| ok,
        .status => |st| return failMsg(st.message),
    };

    var starts_json: std.ArrayList(u8) = .empty;
    for (recorder.starts[0..recorder.start_count], 0..) |s, i| {
        if (i > 0) starts_json.appendSlice(alloc, ",") catch return failMsg("out of memory");
        starts_json.appendSlice(alloc, std.fmt.allocPrint(alloc, "[\"{s}\",\"{s}\",\"{s}\",\"{s}\"]", .{
            s.kind[0..s.kind_len], &s.trace_id, &s.span_id, s.parent_span_id[0..s.parent_len],
        }) catch return failMsg("out of memory")) catch return failMsg("out of memory");
    }
    const json = std.fmt.allocPrint(alloc, "{{\"message\":\"{s}\",\"seenSpan\":\"{s}\",\"starts\":[{s}],\"ends\":{d}}}", .{
        resp.message, &front_state.seen_span, starts_json.items, recorder.end_count,
    }) catch return failMsg("out of memory");
    on_result(json.ptr, json.len);
}
