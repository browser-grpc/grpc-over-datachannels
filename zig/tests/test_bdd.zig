const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const bdd = @import("bdd_scenarios.zig");
const util = @import("test_util.zig");

const Channel = grpcdc.channel.Channel;
const Server = grpcdc.server.Server;
const stubs = examples.echo_grpc_dc;
const CallContext = stubs.CallContext;
const Status = grpcdc.status.Status;
const EchoRequest = examples.echo_messages.EchoRequest;
const EchoResponse = examples.echo_messages.EchoResponse;

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
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return Status.ok();
}

/// BDD: interprets the generated behavior scenarios (bdd_scenarios.zig,
/// generated from the BDD specification; prose in BDD.md) against a
/// loopback client+server. These scenarios are the executable
/// examples, so the documentation cannot drift from the behavior.
pub fn testBdd(alloc: std.mem.Allocator) void {
    var pair = grpcdc.memory_transport.memoryTransportPair(alloc);
    defer pair.deinit(alloc);

    var server = Server.init(alloc);
    defer server.deinit();
    examples.echo_grpc_dc.EchoGrpcDc.registerEchoServer(&server, &examples.echo_service_impl.echo_server_impl);
    _ = server.serveTransport(grpcdc.memory_transport.transportOf(pair.end_b));

    var channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(pair.end_a));
    defer channel.deinit();
    var client = examples.echo_grpc_dc.EchoClient.init(&channel);

    for (bdd.bdd_cases) |c| {
        if (std.mem.eql(u8, c.kind, "unary-trailer")) {
            var md_map = grpcdc.transport.Metadata.init(alloc);
            defer md_map.deinit();
            md_map.put("x-echo-trailer", c.metadata) catch {};
            var stream = switch (channel.serverStream("/echo.Echo/Unary", &req(c.messages[0], 0), &md_map, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "bdd trailer open {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            var resp = examples.echo_messages.EchoResponse{};
            util.check(stream.recvInto(&resp) == .message, "bdd trailer: recv");
            util.check(std.mem.eql(u8, resp.message, c.expect_message) and resp.index == c.expect_num, "bdd trailer: response");
            util.check(stream.recvInto(&resp) == .end, "bdd trailer: EOF");
            var found: ?[]const u8 = null;
            for (stream.trailers) |tp| {
                if (std.mem.eql(u8, tp.key, "x-echo-trailer")) found = tp.value;
            }
            util.check(found != null and std.mem.eql(u8, found.?, c.metadata), "bdd trailer: value");
        } else if (std.mem.eql(u8, c.kind, "unary")) {
            var md: ?grpcdc.transport.Metadata = null;
            var md_map: grpcdc.transport.Metadata = undefined;
            if (c.metadata.len > 0) {
                md_map = grpcdc.transport.Metadata.init(alloc);
                md_map.put("x-echo", c.metadata) catch {};
                md = md_map;
            }
            defer if (md != null) md_map.deinit();
            switch (client.unary(&req(c.messages[0], 0), if (md) |*m| m else null, null)) {
                .ok => |resp| {
                    util.check(c.expect_status < 0, "bdd unary: expected failure");
                    util.check(std.mem.eql(u8, resp.message, c.expect_message) and resp.index == c.expect_num, "bdd unary: response");
                },
                .status => |st| {
                    util.check(c.expect_status >= 0 and st.code == c.expect_status, "bdd unary: status");
                },
            }
        } else if (std.mem.eql(u8, c.kind, "server-stream")) {
            var stream = switch (client.serverStream(&req(c.messages[0], c.count), null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "bdd server-stream open {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            var got: i32 = 0;
            while (true) {
                switch (stream.recv()) {
                    .message => |resp| {
                        util.check(std.mem.eql(u8, resp.message, c.expect_message) and resp.index == got, "bdd server-stream: item");
                        got += 1;
                    },
                    .end => break,
                    .status => |st| {
                        util.checkFmt(false, "bdd server-stream status {d}", .{st.code});
                        break;
                    },
                }
            }
            util.check(got == c.expect_num, "bdd server-stream: count");
        } else if (std.mem.eql(u8, c.kind, "client-stream")) {
            var reqs: std.ArrayList(EchoRequest) = .empty;
            defer reqs.deinit(alloc);
            for (c.messages) |m| reqs.append(alloc, req(m, 0)) catch {};
            switch (client.clientStream(reqs.items, null, null)) {
                .ok => |resp| {
                    util.check(std.mem.eql(u8, resp.message, c.expect_message) and resp.index == c.expect_num, "bdd client-stream: response");
                },
                .status => |st| util.checkFmt(false, "bdd client-stream status {d}", .{st.code}),
            }
        } else if (std.mem.eql(u8, c.kind, "bidi")) {
            var reqs: std.ArrayList(EchoRequest) = .empty;
            defer reqs.deinit(alloc);
            for (c.messages) |m| reqs.append(alloc, req(m, 0)) catch {};
            var stream = switch (client.bidi(reqs.items, null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "bdd bidi open {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            var got: usize = 0;
            while (true) {
                switch (stream.recv()) {
                    .message => |resp| {
                        util.check(got < c.messages.len and std.mem.eql(u8, resp.message, c.messages[got]) and resp.index == @as(i32, @intCast(got)), "bdd bidi: item");
                        got += 1;
                    },
                    .end => break,
                    .status => |st| {
                        util.checkFmt(false, "bdd bidi status {d}", .{st.code});
                        break;
                    },
                }
            }
            util.check(got == @as(usize, @intCast(c.expect_num)), "bdd bidi: count");
        } else if (std.mem.eql(u8, c.kind, "server-stream-fail")) {
            var stream = switch (client.serverStream(&req(c.messages[0], c.count), null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.check(st.code == c.expect_status, "bdd server-stream-fail: open status");
                    continue;
                },
            };
            defer stream.deinit();
            var saw_status = false;
            while (true) {
                switch (stream.recv()) {
                    .message => {},
                    .end => break,
                    .status => |st| {
                        util.check(st.code == c.expect_status, "bdd server-stream-fail: status");
                        saw_status = true;
                        break;
                    },
                }
            }
            util.check(saw_status, "bdd server-stream-fail: no status");
        } else if (std.mem.eql(u8, c.kind, "bidi-fail")) {
            var reqs: std.ArrayList(EchoRequest) = .empty;
            defer reqs.deinit(alloc);
            for (c.messages) |m| reqs.append(alloc, req(m, 0)) catch {};
            var stream = switch (client.bidi(reqs.items, null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.check(st.code == c.expect_status, "bdd bidi-fail: open status");
                    continue;
                },
            };
            defer stream.deinit();
            var saw_status = false;
            while (true) {
                switch (stream.recv()) {
                    .message => {},
                    .end => break,
                    .status => |st| {
                        util.check(st.code == c.expect_status, "bdd bidi-fail: status");
                        saw_status = true;
                        break;
                    },
                }
            }
            util.check(saw_status, "bdd bidi-fail: no status");
        } else if (std.mem.eql(u8, c.kind, "deadline")) {
            var delayed = req(c.messages[0], 0);
            delayed.delay_ms = c.count;
            switch (client.unary(&delayed, null, 100)) {
                .ok => util.check(false, "bdd deadline: expected failure"),
                .status => |st| util.check(st.code == c.expect_status, "bdd deadline: status"),
            }
        } else if (std.mem.eql(u8, c.kind, "cancel")) {
            var stream = switch (client.serverStream(&req(c.messages[0], c.count), null, null)) {
                .ok => |s| s,
                .status => |st| {
                    util.checkFmt(false, "bdd cancel open {d}", .{st.code});
                    unreachable;
                },
            };
            defer stream.deinit();
            switch (stream.recv()) {
                .message => |resp| util.check(std.mem.eql(u8, resp.message, c.messages[0]), "bdd cancel: first"),
                else => util.check(false, "bdd cancel: no first response"),
            }
            stream.stream.cancel();
            var terminated = false;
            var i: i32 = 0;
            while (i < c.count + 2 and !terminated) : (i += 1) {
                switch (stream.recv()) {
                    .message => {},
                    .end => terminated = true,
                    .status => terminated = true,
                }
            }
            util.check(terminated, "bdd cancel: stream did not terminate");
        } else if (std.mem.eql(u8, c.kind, "stream-break")) {
            // Dedicated counting server: abandoning the stream
            // (deinit, no explicit cancel) must RST it so the
            // server stops producing.
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
                var break_stream = switch (break_client.serverStream(&req(c.messages[0], c.count), null, null)) {
                    .ok => |s| s,
                    .status => |st| {
                        util.checkFmt(false, "bdd stream-break open {d}", .{st.code});
                        unreachable;
                    },
                };
                switch (break_stream.recv()) {
                    .message => |r| util.check(std.mem.eql(u8, r.message, c.messages[0]) and r.index == 0, "bdd stream-break: first"),
                    else => util.check(false, "bdd stream-break: no first response"),
                }
                break_stream.deinit(); // abandon the call: sends RST
                std.Thread.sleep(150 * std.time.ns_per_ms);
                const settled = break_produced.load(.monotonic);
                std.Thread.sleep(150 * std.time.ns_per_ms);
                util.check(break_produced.load(.monotonic) == settled, "bdd stream-break: production did not settle");
                util.check(settled < 50, "bdd stream-break: server kept producing");
            }
        } else if (std.mem.eql(u8, c.kind, "raw-unary")) {
            var request = req(c.messages[0], 0);
            var resp = EchoResponse{};
            const st = channel.unary(c.path, &request, &resp, null, null);
            util.check(st.code == c.expect_status, "bdd raw-unary: status");
        } else {
            util.checkFmt(false, "unknown bdd kind: {s}", .{c.kind});
        }
    }
    std.debug.print("TestBdd OK\n", .{});
}
