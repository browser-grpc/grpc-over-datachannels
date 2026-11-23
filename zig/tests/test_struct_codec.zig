const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const Channel = grpcdc.channel.Channel;
const Server = grpcdc.server.Server;
const EchoRequest = examples.echo_messages.EchoRequest;

fn sreq(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

const Setup = struct {
    pair: grpcdc.memory_transport.MemoryPair,
    server: Server,
    channel: Channel,

    fn init(self: *Setup, alloc: std.mem.Allocator, client_struct: bool, server_struct: bool) void {
        self.pair = grpcdc.memory_transport.memoryTransportPair(alloc);
        self.server = Server.init(alloc);
        self.server.setStructCodec(server_struct);
        examples.echo_grpc_dc.EchoGrpcDc.registerEchoServer(&self.server, &examples.echo_service_impl.echo_server_impl);
        _ = self.server.serveTransport(grpcdc.memory_transport.transportOf(self.pair.end_b));
        self.channel = Channel.init(alloc, grpcdc.memory_transport.transportOf(self.pair.end_a));
        self.channel.setStructCodec(client_struct);
    }
};

/// Struct-codec negotiation: struct<->struct roundtrip, mismatch rejected, plain still works.
pub fn testStructCodec(alloc: std.mem.Allocator) void {
    var env: Setup = undefined;
    env.init(alloc, true, true);
    var client = examples.echo_grpc_dc.EchoClient.init(&env.channel);

    const unary = switch (client.unary(&sreq("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "struct unary status {d} {s}", .{ st.code, st.message });
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, unary.message, "echo: hello"), "struct unary");

    var stream = switch (client.serverStream(&sreq("tick", 3), null, null)) {
        .ok => |s| s,
        .status => |st| {
            util.checkFmt(false, "struct serverStream status {d}", .{st.code});
            unreachable;
        },
    };
    defer stream.deinit();
    var n: usize = 0;
    while (true) {
        switch (stream.recv()) {
            .message => n += 1,
            .end => break,
            .status => |st| {
                util.checkFmt(false, "struct stream status {d}", .{st.code});
                unreachable;
            },
        }
    }
    util.check(n == 3, "struct server-stream count");

    const joined = switch (client.clientStream(&.{ sreq("a", 0), sreq("b", 0) }, null, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "struct clientStream status {d}", .{st.code});
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, joined.message, "a+b"), "struct client-stream");

    var bidi = switch (client.bidi(&.{ sreq("x", 0), sreq("y", 0) }, null, null)) {
        .ok => |s| s,
        .status => |st| {
            util.checkFmt(false, "struct bidi status {d}", .{st.code});
            unreachable;
        },
    };
    defer bidi.deinit();
    n = 0;
    while (true) {
        switch (bidi.recv()) {
            .message => n += 1,
            .end => break,
            .status => |st| {
                util.checkFmt(false, "struct bidi recv status {d}", .{st.code});
                unreachable;
            },
        }
    }
    util.check(n == 2, "struct bidi count");

    const struct_bytes = sreq("hello", 0).marshalStruct(alloc);
    defer alloc.free(struct_bytes);
    util.check(struct_bytes.len > 4 and struct_bytes[0] == 'D' and struct_bytes[1] == 'C' and
        struct_bytes[2] == 'S' and struct_bytes[3] == '1', "struct magic");
    var back = EchoRequest{};
    back.unmarshalStruct(alloc, struct_bytes);
    util.check(std.mem.eql(u8, back.message, "hello"), "struct roundtrip");

    var mismatch_env: Setup = undefined;
    mismatch_env.init(alloc, true, false);
    var mismatch = examples.echo_grpc_dc.EchoClient.init(&mismatch_env.channel);
    switch (mismatch.unary(&sreq("hello", 0), null, null)) {
        .ok => util.check(false, "struct client vs plain server should fail"),
        .status => |st| util.check(st.code == grpcdc.wire.codeUnimplemented, "mismatch status"),
    }

    var plain_env: Setup = undefined;
    plain_env.init(alloc, false, true);
    var plain = examples.echo_grpc_dc.EchoClient.init(&plain_env.channel);
    const plain_resp = switch (plain.unary(&sreq("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "plain unary status {d}", .{st.code});
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, plain_resp.message, "echo: hello"), "plain vs struct server");

    std.debug.print("TestStructCodec OK\n", .{});
}
