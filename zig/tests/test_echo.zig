const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const Channel = grpcdc.channel.Channel;
const Server = grpcdc.server.Server;
const EchoRequest = examples.echo_messages.EchoRequest;

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
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

    std.debug.print("TestEcho OK\n", .{});
}
