const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");
const cases = @import("interop_cases.zig");

const stub = examples.interop_test_grpc_dc;
const msgs = examples.interop_messages;
const Empty = examples.interop_empty.Empty;

const TestServiceClient = stub.TestServiceClient;
const UnimplementedServiceClient = stub.UnimplementedServiceClient;

fn payload(alloc: std.mem.Allocator, size: usize) msgs.Payload {
    const body = alloc.alloc(u8, size) catch @panic("out of memory");
    @memset(body, 0);
    return .{ .body = body };
}

fn streamRequest(alloc: std.mem.Allocator, resp_sizes: []const i32, payload_size: usize) msgs.StreamingOutputCallRequest {
    const params = alloc.alloc(msgs.ResponseParameters, resp_sizes.len) catch @panic("out of memory");
    for (resp_sizes, 0..) |size, i| {
        params[i] = .{ .size = size };
    }
    var p = payload(alloc, payload_size);
    return .{ .response_parameters = params, .payload = &p };
}

fn expectStatus(what: []const u8, code: i32, message: []const u8, st: grpcdc.status.Status) void {
    util.checkFmt(st.code == code, "{s}: code {d} != {d}", .{ what, st.code, code });
    if (message.len > 0) {
        util.checkFmt(std.mem.eql(u8, st.message, message), "{s}: message '{s}' != '{s}'", .{ what, st.message, message });
    }
}

fn runCases(alloc: std.mem.Allocator, client: *TestServiceClient, unimpl: *UnimplementedServiceClient) void {
    for (cases.interop_cases) |row| {
        const name = row.name;
        const kind = row.kind;
        if (std.mem.eql(u8, kind, "EMPTY")) {
            const req = Empty{};
            switch (client.emptyCall(&req, null, null)) {
                .ok => {},
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "LARGE_UNARY")) {
            var p = payload(alloc, @intCast(row.req_sizes[0]));
            const req = msgs.SimpleRequest{ .response_size = row.resp_sizes[0], .payload = &p };
            switch (client.unaryCall(&req, null, null)) {
                .ok => |resp| util.checkFmt(resp.payload.?.body.len == @as(usize, @intCast(row.resp_sizes[0])), "{s}: body len", .{name}),
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "CLIENT_STREAMING")) {
            const reqs = alloc.alloc(msgs.StreamingInputCallRequest, row.req_sizes.len) catch @panic("out of memory");
            const payloads = alloc.alloc(msgs.Payload, row.req_sizes.len) catch @panic("out of memory");
            var total: i32 = 0;
            for (row.req_sizes, 0..) |size, i| {
                payloads[i] = payload(alloc, @intCast(size));
                reqs[i] = .{ .payload = &payloads[i] };
                total += size;
            }
            switch (client.streamingInputCall(reqs, null, null)) {
                .ok => |resp| util.checkFmt(resp.aggregated_payload_size == total, "{s}: aggregated {d} != {d}", .{ name, resp.aggregated_payload_size, total }),
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "SERVER_STREAMING")) {
            const req = streamRequest(alloc, row.resp_sizes, 0);
            switch (client.streamingOutputCall(&req, null, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    for (row.resp_sizes) |size| {
                        switch (s.recv()) {
                            .message => |resp| util.checkFmt(resp.payload.?.body.len == @as(usize, @intCast(size)), "{s}: body len", .{name}),
                            else => util.check(false, "server-streaming: early end"),
                        }
                    }
                    switch (s.recv()) {
                        .end => {},
                        else => util.check(false, "server-streaming: expected end"),
                    }
                },
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "PING_PONG")) {
            const reqs = alloc.alloc(msgs.StreamingOutputCallRequest, row.resp_sizes.len) catch @panic("out of memory");
            for (row.resp_sizes, 0..) |size, i| {
                reqs[i] = streamRequest(alloc, &.{size}, @intCast(row.req_sizes[i]));
            }
            switch (client.fullDuplexCall(reqs, null, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    for (row.resp_sizes) |size| {
                        switch (s.recv()) {
                            .message => |resp| util.checkFmt(resp.payload.?.body.len == @as(usize, @intCast(size)), "{s}: body len", .{name}),
                            else => util.check(false, "ping-pong: early end"),
                        }
                    }
                },
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "EMPTY_STREAM")) {
            const reqs: []const msgs.StreamingOutputCallRequest = &.{};
            switch (client.fullDuplexCall(reqs, null, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    switch (s.recv()) {
                        .end => {},
                        else => util.check(false, "empty-stream: expected end"),
                    }
                },
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "CUSTOM_METADATA")) {
            // Upstream custom_metadata, duplex leg (mirrors the Java runner).
            var md = grpcdc.transport.Metadata.init(alloc);
            const trailing_bin = "CgsKCwoL"; // base64 of 0a 0b 0a 0b 0a 0b
            md.put("x-grpc-test-echo-initial", "test_initial_metadata_value") catch @panic("out of memory");
            md.put("x-grpc-test-echo-trailing-bin", trailing_bin) catch @panic("out of memory");
            const reqs = [_]msgs.StreamingOutputCallRequest{streamRequest(alloc, &.{1}, 1)};
            switch (client.fullDuplexCall(&reqs, &md, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    switch (s.recv()) {
                        .message => |resp| util.check(resp.payload.?.body.len == 1, "custom-metadata: body"),
                        else => util.check(false, "custom-metadata: early end"),
                    }
                    switch (s.recv()) {
                        .end => {},
                        else => util.check(false, "custom-metadata: expected end"),
                    }
                    const hdrs = s.headers();
                    util.check(hdrs != null, "custom-metadata: no headers");
                    if (hdrs) |h| {
                        const v = h.metadata.get("x-grpc-test-echo-initial");
                        util.check(v != null and std.mem.eql(u8, v.?, "test_initial_metadata_value"), "custom-metadata: initial");
                    }
                    var found = false;
                    for (s.trailers()) |pair| {
                        if (std.mem.eql(u8, pair.key, "x-grpc-test-echo-trailing-bin") and std.mem.eql(u8, pair.value, trailing_bin)) {
                            found = true;
                        }
                    }
                    util.check(found, "custom-metadata: trailing");
                },
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "STATUS_UNARY")) {
            var echo_status = msgs.EchoStatus{ .code = row.status_code, .message = row.status_message };
            const req = msgs.SimpleRequest{ .response_status = &echo_status };
            switch (client.unaryCall(&req, null, null)) {
                .ok => util.check(false, "status-unary: expected failure"),
                .status => |st| expectStatus(name, row.status_code, row.status_message, st),
            }
        } else if (std.mem.eql(u8, kind, "STATUS_DUPLEX")) {
            var echo_status = msgs.EchoStatus{ .code = row.status_code, .message = row.status_message };
            var req = streamRequest(alloc, &.{0}, 0);
            req.response_status = &echo_status;
            const reqs = [_]msgs.StreamingOutputCallRequest{req};
            switch (client.fullDuplexCall(&reqs, null, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    switch (s.recv()) {
                        .status => |st| expectStatus(name, row.status_code, row.status_message, st),
                        else => util.check(false, "status-duplex: expected status"),
                    }
                },
                .status => |st| expectStatus(name, row.status_code, row.status_message, st),
            }
        } else if (std.mem.eql(u8, kind, "UNIMPLEMENTED_METHOD")) {
            const req = Empty{};
            switch (client.unimplementedCall(&req, null, null)) {
                .ok => util.check(false, "unimplemented-method: expected failure"),
                .status => |st| expectStatus(name, row.status_code, "", st),
            }
        } else if (std.mem.eql(u8, kind, "UNIMPLEMENTED_SERVICE")) {
            const req = Empty{};
            switch (unimpl.unimplementedCall(&req, null, null)) {
                .ok => util.check(false, "unimplemented-service: expected failure"),
                .status => |st| expectStatus(name, row.status_code, "", st),
            }
        } else {
            util.checkFmt(false, "unknown interop kind {s}", .{kind});
        }
        std.debug.print("interop case ok: {s}\n", .{name});
    }
}

/// Interop client grading: the generated Zig TestService client
/// runs the canonical interop cases (generated table:
/// interop_cases.zig) against the official grpc-go
/// TestServiceServer through the bridge. Skips when the server
/// binary is not built (Dockerfile.ci builds it).
pub fn testInteropOracle(alloc: std.mem.Allocator) void {
    const root_path = util.root(alloc);
    const server_bin = std.fmt.allocPrint(alloc, "{s}/oracle/go-interop/interop-server", .{root_path}) catch @panic("out of memory");
    std.fs.cwd().access(server_bin, .{}) catch {
        std.debug.print("TestInteropOracle SKIP (go interop server not built)\n", .{});
        return;
    };
    const port = util.freePort();
    const port_arg = std.fmt.allocPrint(alloc, "{d}", .{port}) catch @panic("out of memory");
    const grpc_arg = std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port}) catch @panic("out of memory");
    const bridge_path = std.fmt.allocPrint(alloc, "{s}/oracle/bridge.mjs", .{root_path}) catch @panic("out of memory");

    var server = util.spawn(alloc, &.{ server_bin, "-port", port_arg }) catch {
        std.debug.print("TestInteropOracle SKIP (go server did not start)\n", .{});
        return;
    };
    defer _ = server.kill() catch {};
    var server_err = util.Drain{};
    util.startDrain(alloc, &server_err, server.stderr.?);

    // The Go server prints no readiness line; poll the port.
    var ready = false;
    var attempts: usize = 0;
    while (attempts < 300) : (attempts += 1) {
        const stream = std.net.tcpConnectToAddress(std.net.Address.parseIp4("127.0.0.1", port) catch unreachable) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        stream.close();
        ready = true;
        break;
    }
    util.check(ready, "go interop server did not start");

    var bridge = util.spawn(alloc, &.{ "node", bridge_path, "dc-to-http2", "--grpc", grpc_arg }) catch {
        std.debug.print("TestInteropOracle SKIP (bridge did not start)\n", .{});
        return;
    };
    defer _ = bridge.kill() catch {};
    var bridge_err = util.Drain{};
    util.startDrain(alloc, &bridge_err, bridge.stderr.?);

    var transport = examples.stdio_transport.StdioTransport.init(alloc, bridge.stdout.?.handle, bridge.stdin.?.handle);
    var channel = grpcdc.channel.Channel.init(alloc, transport.transport());
    defer channel.deinit();
    var client = TestServiceClient.init(&channel);
    var unimpl = UnimplementedServiceClient.init(&channel);
    runCases(alloc, &client, &unimpl);
    std.debug.print("TestInteropOracle OK\n", .{});
}
