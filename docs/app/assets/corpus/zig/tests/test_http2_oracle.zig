const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const runner = @import("scenario_runner.zig");
const util = @import("test_util.zig");

const EchoRequest = examples.echo_messages.EchoRequest;

/// HTTP/2 oracle: the generated grpcdc Http2Transport dials the
/// official grpc-java OracleServer directly over TCP (no
/// bridge). Skips when the oracle is unavailable. Mirrors
/// java/tests/TestHttp2Oracle.java, except the TLS leg: the
/// generated Zig transport has no stdlib TLS that can negotiate
/// ALPN h2 here, so that leg reports a clear SKIP (dialTls
/// returns error.TlsUnsupported; it never silently dials
/// cleartext).
pub fn testHttp2Oracle(alloc: std.mem.Allocator) void {
    const root_path = util.root(alloc);
    const cp = util.javaClasspath(alloc, root_path) orelse {
        std.debug.print("TestHttp2Oracle SKIP (java oracle not built)\n", .{});
        return;
    };
    const port = util.freePort();
    const port_str = std.fmt.allocPrint(alloc, "{d}", .{port}) catch unreachable;
    var server = util.spawn(alloc, &.{ "java", "-cp", cp, "dc.oracle.OracleServer", port_str }) catch {
        std.debug.print("TestHttp2Oracle SKIP (oracle server did not start)\n", .{});
        return;
    };
    defer util.killChild(&server);
    var server_err = util.Drain{};
    util.startDrain(alloc, &server_err, server.stderr.?);
    if (!util.waitReady(&server_err, "READY", 60000)) {
        std.debug.print("TestHttp2Oracle SKIP (oracle server did not start)\n", .{});
        return;
    }
    const authority = std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port}) catch unreachable;
    var http2 = grpcdc.http2_transport.Http2Transport.dial(alloc, authority) catch |err| {
        std.debug.print("TestHttp2Oracle FAIL dial: {s}\n", .{@errorName(err)});
        util.check(false, "http2 dial");
        return;
    };
    defer http2.deinit();
    {
        var channel = grpcdc.channel.Channel.init(alloc, http2.transport());
        defer channel.deinit();
        var client = examples.echo_grpc_dc.EchoClient.init(&channel);
        runner.runScenarios(alloc, &client);
        // Echoed initial metadata proves HEADERS metadata made
        // the round trip.
        var md = grpcdc.transport.Metadata.init(alloc);
        defer md.deinit();
        md.put("x-echo", "mval") catch {};
        var req = EchoRequest{ .message = "hello", .count = 0 };
        switch (client.unary(&req, &md, null)) {
            .ok => |resp| {
                util.check(std.mem.eql(u8, resp.message, "echo: hello [mval]"), "metadata echo");
            },
            .status => |st| {
                std.debug.print("metadata unary status {d} {s}\n", .{ st.code, st.message });
                util.check(false, "metadata unary");
            },
        }
        // 200 responses x 1500-byte payloads: comfortably past
        // several 64KiB flow-control windows, so the call only
        // completes if stream/connection WINDOW_UPDATE
        // accounting replenishes.
        const big = alloc.alloc(u8, 1500) catch unreachable;
        @memset(big, 'y');
        var big_req = EchoRequest{ .message = big, .count = 200 };
        var stream = switch (client.serverStream(&big_req, null, null)) {
            .ok => |s| s,
            .status => |st| {
                std.debug.print("flow open status {d}\n", .{st.code});
                util.check(false, "flow open");
                return;
            },
        };
        defer stream.deinit();
        var got: i32 = 0;
        while (true) {
            switch (stream.recv()) {
                .message => |resp| {
                    util.check(std.mem.eql(u8, resp.message, big) and resp.index == got, "flow response");
                    got += 1;
                },
                .end => break,
                .status => |st| {
                    std.debug.print("flow status {d} {s}\n", .{ st.code, st.message });
                    util.check(false, "flow status");
                    break;
                },
            }
        }
        util.check(got == 200, "flow count");
    }
    http2.close();
    // gzip codec (stdlib flate): roundtrip through the helpers
    // the transport's compression path uses.
    {
        const plain = "grpc-dc zig gzip roundtrip " ** 40;
        const gz = grpcdc.http2_transport.Http2Transport.gzip(alloc, plain) catch {
            util.check(false, "gzip compress");
            return;
        };
        defer alloc.free(gz);
        const back = grpcdc.http2_transport.Http2Transport.gunzip(alloc, gz) catch {
            util.check(false, "gzip decompress");
            return;
        };
        defer alloc.free(back);
        util.check(std.mem.eql(u8, back, plain), "gzip roundtrip");
    }
    // TLS leg: unavailable in the generated Zig transport.
    std.debug.print("TestHttp2Oracle TLS SKIP (no stdlib TLS ALPN h2 for generated Zig transport)\n", .{});
    std.debug.print("TestHttp2Oracle OK\n", .{});
}
