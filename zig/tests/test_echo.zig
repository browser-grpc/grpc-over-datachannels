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

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

var break_produced = std.atomic.Value(i32).init(0);

fn breakServerStream(_: *anyopaque, _: *CallContext, request: *const EchoRequest, stream: *stubs.EchoServerStreamServer) Status {
    var i: i32 = 0;
    while (i < request.count) : (i += 1) {
        _ = break_produced.fetchAdd(1, .monotonic);
        var resp = EchoResponse{ .message = request.message, .index = i };
        const st = stream.send(&resp);
        if (!st.isOk()) return st;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return Status.ok();
}

// Inline (single-threaded server) stream-break fixtures: a queue
// transport whose server end offers try_recv, so the server
// endpoint runs in inline pump mode with no read thread.
const InlineQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    items: std.ArrayList([]u8) = .empty,
    closed: bool = false,
};

const InlineEnd = struct {
    inbox: *InlineQueue,
    outbox: *InlineQueue,
    alloc: std.mem.Allocator,
    closed: bool = false,

    fn send(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *InlineEnd = @ptrCast(@alignCast(ctx));
        self.outbox.mutex.lock();
        defer self.outbox.mutex.unlock();
        if (self.closed or self.outbox.closed) return error.Closed;
        const copy = try self.alloc.dupe(u8, data);
        try self.outbox.items.append(self.alloc, copy);
        self.outbox.cond.signal();
    }
    fn recv(ctx: *anyopaque, alloc2: std.mem.Allocator) anyerror!?[]u8 {
        const self: *InlineEnd = @ptrCast(@alignCast(ctx));
        _ = alloc2;
        self.inbox.mutex.lock();
        defer self.inbox.mutex.unlock();
        while (self.inbox.items.items.len == 0) {
            if (self.inbox.closed or self.closed) return null;
            self.inbox.cond.wait(&self.inbox.mutex);
        }
        return self.inbox.items.orderedRemove(0);
    }
    fn tryRecv(ctx: *anyopaque, alloc2: std.mem.Allocator) anyerror!?[]u8 {
        const self: *InlineEnd = @ptrCast(@alignCast(ctx));
        _ = alloc2;
        self.inbox.mutex.lock();
        defer self.inbox.mutex.unlock();
        if (self.inbox.items.items.len == 0) {
            if (self.inbox.closed or self.closed) return null;
            return error.WouldBlock;
        }
        return self.inbox.items.orderedRemove(0);
    }
    fn close(ctx: *anyopaque) void {
        const self: *InlineEnd = @ptrCast(@alignCast(ctx));
        self.closed = true;
        self.inbox.mutex.lock();
        self.inbox.closed = true;
        self.inbox.cond.broadcast();
        self.inbox.mutex.unlock();
    }
};

var inline_break_done = std.atomic.Value(bool).init(false);
var inline_client_done = std.atomic.Value(bool).init(false);

fn inlineBreakServerStream(_: *anyopaque, _: *CallContext, request: *const EchoRequest, stream: *stubs.EchoServerStreamServer) Status {
    defer inline_break_done.store(true, .monotonic);
    var i: i32 = 0;
    while (i < request.count) : (i += 1) {
        _ = break_produced.fetchAdd(1, .monotonic);
        var resp = EchoResponse{ .message = request.message, .index = i };
        const st = stream.send(&resp);
        if (!st.isOk()) return st;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    return Status.ok();
}

fn inlineBreakClient(channel: *Channel) void {
    defer inline_client_done.store(true, .monotonic);
    var client = stubs.EchoClient.init(channel);
    var stream = switch (client.serverStream(&req("tick", 200), null, null)) {
        .ok => |s| s,
        .status => return,
    };
    switch (stream.recv()) {
        .message => |r| util.check(r.index == 0, "inline stream-break first response"),
        .end => util.check(false, "inline stream-break ended early"),
        .status => |st| util.checkFmt(false, "inline stream-break recv status {d}", .{st.code}),
    }
    stream.deinit(); // abandon the call: sends RST
}

/// Loopback end-to-end: all four shapes, error status, metadata.
pub fn testEcho(alloc: std.mem.Allocator) void {
    var pair = grpcdc.memory_transport.memoryTransportPair(alloc);
    defer pair.deinit(alloc);

    var server = Server.init(alloc);
    defer server.deinit();
    examples.echo_grpc_dc.EchoGrpcDc.registerEchoServer(&server, &examples.echo_service_impl.echo_server_impl);
    _ = server.serveTransport(grpcdc.memory_transport.transportOf(pair.end_b));

    var channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(pair.end_a));
    defer channel.deinit();
    var client = examples.echo_grpc_dc.EchoClient.init(&channel);

    const unary = switch (client.unary(&req("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "unary status {d} {s}", .{ st.code, st.message });
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, unary.message, "echo: hello") and unary.index == 0, "unary");

    var stream = switch (client.serverStream(&req("tick", 3), null, null)) {
        .ok => |s| s,
        .status => |st| {
            util.checkFmt(false, "serverStream status {d}", .{st.code});
            unreachable;
        },
    };
    defer stream.deinit();
    var indexes: [3]i32 = undefined;
    var n: usize = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |resp| {
                util.check(std.mem.eql(u8, resp.message, "tick"), "stream message");
                if (n < 3) indexes[n] = resp.index;
                n += 1;
            },
            .end => break,
            .status => |st| {
                util.checkFmt(false, "stream status {d}", .{st.code});
                break;
            },
        }
    }
    util.check(n == 3 and indexes[0] == 0 and indexes[1] == 1 and indexes[2] == 2, "stream indexes");

    const joined = switch (client.clientStream(&.{ req("a", 0), req("b", 0), req("c", 0) }, null, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "clientStream status {d}", .{st.code});
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, joined.message, "a+b+c") and joined.index == 3, "client stream");

    var bidi = switch (client.bidi(&.{ req("x", 0), req("y", 0) }, null, null)) {
        .ok => |s| s,
        .status => |st| {
            util.checkFmt(false, "bidi status {d}", .{st.code});
            unreachable;
        },
    };
    defer bidi.deinit();
    var echoed: [2][]const u8 = undefined;
    var m: usize = 0;
    while (true) {
        switch (bidi.recv()) {
            .message => |resp| {
                if (m < 2) echoed[m] = resp.message;
                m += 1;
            },
            .end => break,
            .status => |st| {
                util.checkFmt(false, "bidi recv status {d}", .{st.code});
                break;
            },
        }
    }
    util.check(m == 2 and std.mem.eql(u8, echoed[0], "x") and std.mem.eql(u8, echoed[1], "y"), "bidi");

    switch (client.unary(&req("fail", 0), null, null)) {
        .ok => util.check(false, "fail call should fail"),
        .status => |st| util.check(st.code == 3, "fail status"),
    }

    var md = grpcdc.transport.Metadata.init(alloc);
    defer md.deinit();
    md.put("x-echo", "meta") catch {};
    const with_md = switch (client.unary(&req("hello", 0), &md, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "metadata status {d}", .{st.code});
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, with_md.message, "echo: hello [meta]"), "metadata");

    // Breaking a server stream cancels it server-side: deinit of
    // the client stream before trailers sends RST CANCELLED, and
    // the handler's next send fails instead of producing forever.
    break_produced.store(0, .monotonic);
    {
        var break_pair = grpcdc.memory_transport.memoryTransportPair(alloc);
        defer break_pair.deinit(alloc);
        var break_impl = stubs.EchoServer{
            .ctx = undefined,
            .unary_fn = examples.echo_service_impl.echo_server_impl.unary_fn,
            .server_stream_fn = breakServerStream,
            .client_stream_fn = examples.echo_service_impl.echo_server_impl.client_stream_fn,
            .bidi_fn = examples.echo_service_impl.echo_server_impl.bidi_fn,
        };
        var break_server = Server.init(alloc);
        defer break_server.deinit();
        stubs.EchoGrpcDc.registerEchoServer(&break_server, &break_impl);
        _ = break_server.serveTransport(grpcdc.memory_transport.transportOf(break_pair.end_b));
        var break_channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(break_pair.end_a));
        defer break_channel.deinit();
        var break_client = stubs.EchoClient.init(&break_channel);
        var break_stream = switch (break_client.serverStream(&req("tick", 200), null, null)) {
            .ok => |s| s,
            .status => |st| {
                util.checkFmt(false, "stream-break open status {d}", .{st.code});
                unreachable;
            },
        };
        switch (break_stream.recv()) {
            .message => |r| util.check(r.index == 0, "stream-break first response"),
            .end => util.check(false, "stream-break ended early"),
            .status => |st| util.checkFmt(false, "stream-break recv status {d}", .{st.code}),
        }
        break_stream.deinit(); // abandon the call: sends RST
        std.Thread.sleep(100 * std.time.ns_per_ms);
        const settled = break_produced.load(.monotonic);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        util.check(break_produced.load(.monotonic) == settled, "stream-break production did not settle");
        util.check(settled < 100, "stream-break server kept producing");
    }

    // Same break with an inline (single-threaded) server: the
    // handler runs on the pollOnce stack, so its sends must pump
    // the endpoint or the client's RST is never observed.
    {
        break_produced.store(0, .monotonic);
        inline_break_done.store(false, .monotonic);
        inline_client_done.store(false, .monotonic);
        var a_to_b = InlineQueue{};
        var b_to_a = InlineQueue{};
        var end_a = InlineEnd{ .inbox = &b_to_a, .outbox = &a_to_b, .alloc = alloc };
        var end_b = InlineEnd{ .inbox = &a_to_b, .outbox = &b_to_a, .alloc = alloc };
        var inline_impl = stubs.EchoServer{
            .ctx = undefined,
            .unary_fn = examples.echo_service_impl.echo_server_impl.unary_fn,
            .server_stream_fn = inlineBreakServerStream,
            .client_stream_fn = examples.echo_service_impl.echo_server_impl.client_stream_fn,
            .bidi_fn = examples.echo_service_impl.echo_server_impl.bidi_fn,
        };
        var inline_server = Server.init(alloc);
        defer inline_server.deinit();
        stubs.EchoGrpcDc.registerEchoServer(&inline_server, &inline_impl);
        const server_ep = inline_server.serveTransport(.{
            .ctx = &end_b,
            .send_fn = InlineEnd.send,
            .recv_fn = InlineEnd.recv,
            .close_fn = InlineEnd.close,
            .try_recv_fn = InlineEnd.tryRecv,
        });
        util.check(server_ep.inline_pump, "inline stream-break server is inline");
        var inline_channel = Channel.init(alloc, .{
            .ctx = &end_a,
            .send_fn = InlineEnd.send,
            .recv_fn = InlineEnd.recv,
            .close_fn = InlineEnd.close,
        });
        defer inline_channel.deinit();
        const client_thread = std.Thread.spawn(.{}, inlineBreakClient, .{&inline_channel}) catch {
            util.check(false, "inline stream-break client thread");
            unreachable;
        };
        var waited_ms: usize = 0;
        while (waited_ms < 8000) : (waited_ms += 1) {
            server_ep.pollOnce();
            if (inline_client_done.load(.monotonic) and inline_break_done.load(.monotonic)) break;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        client_thread.join();
        util.check(inline_client_done.load(.monotonic), "inline stream-break client finished");
        util.check(inline_break_done.load(.monotonic), "inline stream-break handler finished");
        std.Thread.sleep(100 * std.time.ns_per_ms);
        const settled = break_produced.load(.monotonic);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        util.check(break_produced.load(.monotonic) == settled, "inline stream-break production did not settle");
        util.check(settled < 100, "inline stream-break server kept producing");
    }

    std.debug.print("TestEcho OK\n", .{});
}
