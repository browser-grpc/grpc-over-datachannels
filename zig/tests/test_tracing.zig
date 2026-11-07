const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const Channel = grpcdc.channel.Channel;
const Server = grpcdc.server.Server;
const stubs = examples.echo_grpc_dc;
const CallContext = stubs.CallContext;
const EchoRequest = examples.echo_messages.EchoRequest;
const EchoResponse = examples.echo_messages.EchoResponse;
const Status = grpcdc.status.Status;
const status_mod = grpcdc.status;

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

const Start = struct {
    kind: [16]u8,
    kind_len: usize,
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: [16]u8,
    has_parent: bool,
};

const Recorder = struct {
    starts: [8]Start = undefined,
    start_count: usize = 0,
    end_count: usize = 0,

    fn onStart(ctx: *anyopaque, kind: []const u8, method: []const u8, trace_id: []const u8, span_id: []const u8, parent_span_id: []const u8) void {
        _ = method;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var s = Start{
            .kind = [_]u8{0} ** 16,
            .kind_len = kind.len,
            .trace_id = [_]u8{0} ** 32,
            .span_id = [_]u8{0} ** 16,
            .parent_span_id = [_]u8{0} ** 16,
            .has_parent = parent_span_id.len != 0,
        };
        @memcpy(s.kind[0..kind.len], kind);
        @memcpy(&s.trace_id, trace_id[0..32]);
        @memcpy(&s.span_id, span_id[0..16]);
        if (parent_span_id.len != 0) @memcpy(&s.parent_span_id, parent_span_id[0..16]);
        self.starts[self.start_count] = s;
        self.start_count += 1;
    }

    fn onEnd(ctx: *anyopaque, kind: []const u8, method: []const u8, trace_id: []const u8, span_id: []const u8, status: []const u8, duration_ms: f64) void {
        _ = kind;
        _ = method;
        _ = trace_id;
        _ = span_id;
        _ = status;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        util.check(duration_ms >= 0, "duration");
        self.end_count += 1;
    }
};

const Front = struct {
    downstream: *Channel,
    seen_span: [16]u8 = [_]u8{0} ** 16,
};

fn frontUnary(ctx: *anyopaque, call_ctx: *CallContext, request: *const EchoRequest, resp: *EchoResponse, alloc: std.mem.Allocator) Status {
    _ = request;
    _ = alloc;
    const front: *Front = @ptrCast(@alignCast(ctx));
    if (call_ctx.trace_context) |tc| front.seen_span = tc.span_id;
    front.downstream.setTraceContext(call_ctx.trace_context);
    var client = stubs.EchoClient.init(front.downstream);
    var r = req("nested", 0);
    switch (client.unary(&r, null, null)) {
        .ok => |ok| {
            resp.* = ok;
            return Status.ok();
        },
        .status => |st| return st,
    }
}

/// Tracing: nested callee call joins the trace via the bound channel.
pub fn testTracing(alloc: std.mem.Allocator) void {
    var recorder = Recorder{};
    status_mod.setTracer(.{ .ctx = &recorder, .on_start = Recorder.onStart, .on_end = Recorder.onEnd });
    defer status_mod.setTracer(null);

    var back_pair = grpcdc.memory_transport.memoryTransportPair(alloc);
    defer back_pair.deinit(alloc);
    var back = Server.init(alloc);
    defer back.deinit();
    var back_impl = examples.echo_service_impl.echo_server_impl;
    stubs.EchoGrpcDc.registerEchoServer(&back, &back_impl);
    _ = back.serveTransport(grpcdc.memory_transport.transportOf(back_pair.end_b));
    var downstream_channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(back_pair.end_a));
    defer downstream_channel.deinit();

    var front_state = Front{ .downstream = &downstream_channel };
    var front_impl = stubs.EchoServer{
        .ctx = &front_state,
        .unary_fn = frontUnary,
        .server_stream_fn = examples.echo_service_impl.echo_server_impl.server_stream_fn,
        .client_stream_fn = examples.echo_service_impl.echo_server_impl.client_stream_fn,
        .bidi_fn = examples.echo_service_impl.echo_server_impl.bidi_fn,
    };
    var pair = grpcdc.memory_transport.memoryTransportPair(alloc);
    defer pair.deinit(alloc);
    var front_server = Server.init(alloc);
    defer front_server.deinit();
    stubs.EchoGrpcDc.registerEchoServer(&front_server, &front_impl);
    _ = front_server.serveTransport(grpcdc.memory_transport.transportOf(pair.end_b));
    var channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(pair.end_a));
    defer channel.deinit();
    var client = stubs.EchoClient.init(&channel);

    var r = req("hello", 0);
    const resp = switch (client.unary(&r, null, null)) {
        .ok => |ok| ok,
        .status => |st| {
            util.check(false, st.message);
            return;
        },
    };
    util.check(std.mem.eql(u8, resp.message, "echo: nested"), "resp message");

    util.check(recorder.start_count == 4, "starts count");
    const starts = recorder.starts[0..4];
    util.check(std.mem.eql(u8, starts[0].kind[0..starts[0].kind_len], "client"), "kind 0");
    util.check(std.mem.eql(u8, starts[1].kind[0..starts[1].kind_len], "server"), "kind 1");
    util.check(std.mem.eql(u8, starts[2].kind[0..starts[2].kind_len], "client"), "kind 2");
    util.check(std.mem.eql(u8, starts[3].kind[0..starts[3].kind_len], "server"), "kind 3");
    for (starts) |s| util.check(std.mem.eql(u8, &s.trace_id, &starts[0].trace_id), "trace ids");
    util.check(std.mem.eql(u8, &starts[1].parent_span_id, &starts[0].span_id), "server parent");
    util.check(std.mem.eql(u8, &starts[2].parent_span_id, &starts[1].span_id), "inner client parent");
    util.check(std.mem.eql(u8, &starts[3].parent_span_id, &starts[2].span_id), "inner server parent");
    util.check(std.mem.eql(u8, &front_state.seen_span, &starts[1].span_id), "ctx span");
    util.check(recorder.end_count == 4, "ends count");
    std.debug.print("TestTracing OK\n", .{});
}
