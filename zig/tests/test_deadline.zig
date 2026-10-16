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
const wire = grpcdc.wire;

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

var seen_ctx: ?CallContext = null;

fn slowUnary(_: *anyopaque, ctx: *CallContext, request: *const EchoRequest, resp: *EchoResponse, alloc: std.mem.Allocator) Status {
    seen_ctx = ctx.*;
    std.Thread.sleep(400 * std.time.ns_per_ms);
    resp.message = std.fmt.allocPrint(alloc, "echo: {s}", .{request.message}) catch
        return Status.init(wire.codeResourceExhausted, "out of memory");
    resp.index = 0;
    return Status.ok();
}

fn slowServerStream(_: *anyopaque, _: *CallContext, request: *const EchoRequest, stream: *stubs.EchoServerStreamServer) Status {
    var i: i32 = 0;
    while (i < request.count) : (i += 1) {
        if (i > 0) std.Thread.sleep(300 * std.time.ns_per_ms);
        var resp = EchoResponse{ .message = request.message, .index = i };
        const st = stream.send(&resp);
        if (!st.isOk()) return st;
    }
    return Status.ok();
}


/// Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED.
pub fn testDeadline(alloc: std.mem.Allocator) void {
    {
        const enc = grpcdc.codec.Codec.encodeTimeout(alloc, 250);
        defer alloc.free(enc);
        util.check(grpcdc.codec.Codec.parseTimeout(enc) == 250, "timeout round trip");
        util.check(grpcdc.codec.Codec.parseTimeout("10x") == null, "junk timeout");
    }

    var pair = grpcdc.memory_transport.memoryTransportPair(alloc);
    defer pair.deinit(alloc);

    var slow_impl = stubs.EchoServer{
        .ctx = undefined,
        .unary_fn = slowUnary,
        .server_stream_fn = slowServerStream,
        .client_stream_fn = examples.echo_service_impl.echo_server_impl.client_stream_fn,
        .bidi_fn = examples.echo_service_impl.echo_server_impl.bidi_fn,
    };

    var server = Server.init(alloc);
    defer server.deinit();
    stubs.EchoGrpcDc.registerEchoServer(&server, &slow_impl);
    _ = server.serveTransport(grpcdc.memory_transport.transportOf(pair.end_b));

    var channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(pair.end_a));
    defer channel.deinit();
    var client = stubs.EchoClient.init(&channel);

    const start = std.time.milliTimestamp();
    switch (client.unary(&req("hello", 0), null, 50)) {
        .ok => util.check(false, "expected deadline"),
        .status => |st| util.check(st.code == wire.codeDeadlineExceeded, "unary code"),
    }
    util.check(std.time.milliTimestamp() - start < 350, "deadline fires fast");
    util.check(seen_ctx != null, "handler ran");
    util.check(seen_ctx.?.metadata.contains("grpc-timeout"), "grpc-timeout metadata");
    util.check(seen_ctx.?.deadline_ms != null, "ctx deadline");
    util.check(seen_ctx.?.timeRemainingMs() != null, "ctx remaining");

    var stream = switch (client.serverStream(&req("tick", 5), null, 150)) {
        .ok => |s| s,
        .status => |st| {
            util.checkFmt(false, "serverStream status {d}", .{st.code});
            unreachable;
        },
    };
    defer stream.deinit();
    switch (stream.recv()) {
        .message => |r| util.check(r.index == 0, "stream first"),
        .status => |st| util.checkFmt(false, "stream first status {d}", .{st.code}),
        .end => util.check(false, "stream eos early"),
    }
    switch (stream.recv()) {
        .message => util.check(false, "expected stream deadline"),
        .status => |st| util.check(st.code == wire.codeDeadlineExceeded, "stream code"),
        .end => util.check(false, "stream eos instead of deadline"),
    }

    const joined = switch (client.clientStream(&.{ req("a", 0), req("b", 0) }, null, 5000)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "joined status {d}", .{st.code});
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, joined.message, "a+b"), "generous timeout");
}
