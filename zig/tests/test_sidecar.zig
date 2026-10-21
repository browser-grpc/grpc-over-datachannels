const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const Channel = grpcdc.channel.Channel;
const Server = grpcdc.server.Server;
const EchoRequest = examples.echo_messages.EchoRequest;

// gRPC over WebRTC-Direct via the Rust sidecar, Zig to Zig:
// two direct_sidecar processes own the WebRTC stack; the Zig
// server and client only speak length-prefixed TCP to their
// local sidecar (grpcdc.sidecar_transport.SidecarTransport).

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

fn rootPath(alloc: std.mem.Allocator) []const u8 {
    for ([_][]const u8{ ".", ".." }) |start| {
        const marker = std.fs.path.join(alloc, &.{ start, "webrtc/rust/Cargo.toml" }) catch continue;
        std.fs.cwd().access(marker, .{}) catch continue;
        return start;
    }
    return ".";
}

fn sidecarBin(alloc: std.mem.Allocator) []const u8 {
    const root = rootPath(alloc);
    const bin = std.fs.path.join(alloc, &.{ root, "webrtc/rust/target/debug/examples/direct_sidecar" }) catch unreachable;
    std.fs.cwd().access(bin, .{}) catch {
        var child = std.process.Child.init(
            &.{ "cargo", "build", "--example", "direct_sidecar" },
            alloc,
        );
        child.cwd = std.fs.path.join(alloc, &.{ root, "webrtc/rust" }) catch unreachable;
        const term = child.spawnAndWait() catch unreachable;
        util.check(term.Exited == 0, "cargo build direct_sidecar");
    };
    return bin;
}

fn freePort() u16 {
    const addr = std.net.Address.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = addr.listen(.{}) catch unreachable;
    defer server.deinit();
    return server.listen_address.getPort();
}

fn readLine(child: *std.process.Child, needle: []const u8, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    child.stdout.?.reader().streamUntilDelimiter(fbs.writer(), '\n', buf.len) catch unreachable;
    const line = fbs.getWritten();
    _ = needle;
    return line;
}

fn waitLine(alloc: std.mem.Allocator, child: *std.process.Child, needle: []const u8) []const u8 {
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = child.stdout.?.read(buf[total .. total + 1]) catch unreachable;
        util.check(n == 1, "sidecar exited");
        total += n;
        if (buf[total - 1] == '\n') break;
    }
    const line = std.mem.trim(u8, buf[0..total], " \r\n");
    util.check(std.mem.indexOf(u8, line, needle) != null, "sidecar line missing needle");
    _ = alloc;
    return line;
}

const ServerCtx = struct {
    server: *Server,
    listener: *std.net.Server,
    sidecar: *grpcdc.sidecar_transport.SidecarTransport,

    fn run(ctx: *ServerCtx, alloc: std.mem.Allocator) void {
        const conn = ctx.listener.accept() catch return;
        ctx.sidecar.* = .{ .stream = conn.stream };
        _ = ctx.server.serveTransport(ctx.sidecar.transport());
        _ = alloc;
    }
};

pub fn testSidecar(alloc: std.mem.Allocator) void {
    const bin = sidecarBin(alloc);
    const lang_port = freePort();

    var server = Server.init(alloc);
    defer server.deinit();
    examples.echo_grpc_dc.EchoGrpcDc.registerEchoServer(&server, &examples.echo_service_impl.echo_server_impl);

    const addr = std.net.Address.parseIp4("127.0.0.1", lang_port) catch unreachable;
    var listener = addr.listen(.{ .reuse_address = true }) catch unreachable;
    defer listener.deinit();

    var sidecar_holder: grpcdc.sidecar_transport.SidecarTransport = undefined;
    var ctx = ServerCtx{ .server = &server, .listener = &listener, .sidecar = &sidecar_holder };
    const thread = std.Thread.spawn(.{}, ServerCtx.run, .{ &ctx, alloc }) catch unreachable;
    _ = thread;

    var listen_child = std.process.Child.init(
        &.{ bin, "listen", "--udp", "127.0.0.1:0", "--tcp", std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{lang_port}) catch unreachable },
        alloc,
    );
    listen_child.stdout_behavior = .Pipe;
    listen_child.stderr_behavior = .Ignore;
    listen_child.spawn() catch unreachable;
    const ma_line = waitLine(alloc, &listen_child, "MULTIADDR");
    const multiaddr = ma_line[std.mem.indexOf(u8, ma_line, " ").? + 1 ..];
    util.check(std.mem.indexOf(u8, multiaddr, "/webrtc-direct/certhash/f") != null, "multiaddr");

    const client_port = freePort();
    var dial_child = std.process.Child.init(
        &.{ bin, "dial", "--multiaddr", multiaddr, "--tcp", std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{client_port}) catch unreachable },
        alloc,
    );
    dial_child.stdout_behavior = .Pipe;
    dial_child.stderr_behavior = .Ignore;
    dial_child.spawn() catch unreachable;
    _ = waitLine(alloc, &dial_child, "TCP");

    const transport = grpcdc.sidecar_transport.SidecarTransport.connect(alloc, "127.0.0.1", client_port) catch unreachable;
    var channel = Channel.init(alloc, transport.transport());
    defer channel.deinit();
    var client = examples.echo_grpc_dc.EchoClient.init(&channel);

    const unary = switch (client.unary(&req("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| {
            util.checkFmt(false, "unary status {d} {s}", .{ st.code, st.message });
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, unary.message, "echo: hello"), "sidecar unary");

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
                if (n < 3) indexes[n] = resp.index;
                n += 1;
            },
            .end => break,
            .status => break,
        }
    }
    util.check(n == 3 and indexes[0] == 0 and indexes[1] == 1 and indexes[2] == 2, "stream indexes");

    _ = dial_child.kill() catch {};
    _ = listen_child.kill() catch {};
    std.debug.print("TestSidecar OK\n", .{});
}
