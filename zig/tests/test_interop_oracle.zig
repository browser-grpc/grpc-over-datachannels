const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");
const cases = @import("interop_cases.zig");

const stub = examples.interop_test_grpc_dc;
const orca_stub = examples.interop_orca_grpc_dc;
const orca_msgs = examples.interop_orca_load_report_messages;
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

fn runCases(alloc: std.mem.Allocator, channel: *grpcdc.channel.Channel, client: *TestServiceClient, unimpl: *UnimplementedServiceClient) void {
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
        } else if (std.mem.eql(u8, kind, "SPECIAL_STATUS")) {
            var echo_status = msgs.EchoStatus{ .code = row.status_code, .message = row.status_message };
            const req = msgs.SimpleRequest{ .response_status = &echo_status };
            switch (client.unaryCall(&req, null, null)) {
                .ok => util.check(false, "special-status: expected failure"),
                .status => |st| expectStatus(name, row.status_code, row.status_message, st),
            }
        } else if (std.mem.eql(u8, kind, "CANCEL_AFTER_BEGIN")) {
            // Begin a client-streaming call and cancel it before
            // sending any request: the pending recv must report
            // CANCELLED.
            switch (channel.openStream("/grpc.testing.TestService/StreamingInputCall", null, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    s.cancel();
                    var resp = msgs.StreamingInputCallResponse{};
                    switch (s.recvInto(&resp)) {
                        .status => |st| expectStatus(name, row.status_code, "", st),
                        else => util.check(false, "cancel-after-begin: expected status"),
                    }
                },
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "CANCEL_AFTER_FIRST")) {
            // Duplex call (no half-close): the server answers the
            // one request, then waits for more input, so the cancel
            // deterministically lands mid-call (same shape as the
            // Python/JS suites).
            switch (channel.openStream("/grpc.testing.TestService/FullDuplexCall", null, null)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    const req = streamRequest(alloc, &.{row.resp_sizes[0]}, 1);
                    const send_st = s.send(req);
                    util.check(send_st.isOk(), "cancel-after-first: send");
                    var resp = msgs.StreamingOutputCallResponse{};
                    switch (s.recvInto(&resp)) {
                        .message => util.check(resp.payload.?.body.len == @as(usize, @intCast(row.resp_sizes[0])), "cancel-after-first: body len"),
                        else => util.check(false, "cancel-after-first: early end"),
                    }
                    s.cancel();
                    var resp2 = msgs.StreamingOutputCallResponse{};
                    switch (s.recvInto(&resp2)) {
                        .status => |st| expectStatus(name, row.status_code, "", st),
                        else => util.check(false, "cancel-after-first: expected status"),
                    }
                },
                .status => |st| util.checkFmt(false, "{s}: status {d}", .{ name, st.code }),
            }
        } else if (std.mem.eql(u8, kind, "TIMEOUT_SLEEPING")) {
            const params = alloc.alloc(msgs.ResponseParameters, row.resp_sizes.len) catch @panic("out of memory");
            for (row.resp_sizes, 0..) |size, i| {
                params[i] = .{ .size = size, .interval_us = 1000000 };
            }
            var p = payload(alloc, 0);
            const req = msgs.StreamingOutputCallRequest{ .response_parameters = params, .payload = &p };
            switch (client.streamingOutputCall(&req, null, 100)) {
                .ok => |stream| {
                    var s = stream;
                    defer s.deinit();
                    switch (s.recv()) {
                        .status => |st| expectStatus(name, row.status_code, "", st),
                        else => util.check(false, "timeout-on-sleeping-server: expected status"),
                    }
                },
                .status => |st| expectStatus(name, row.status_code, "", st),
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

// Compression rows (upstream client_compressed_unary,
// client_compressed_streaming, server_compressed_unary,
// server_compressed_streaming): the DataChannel wire is
// compression-free; the client declares grpc-encoding: gzip
// and the bridge gzips request messages on the HTTP/2 hop,
// decompressing responses the same way.
fn runCompressionCases(alloc: std.mem.Allocator, client: *TestServiceClient) void {
    var md = grpcdc.transport.Metadata.init(alloc);
    defer md.deinit();
    md.put("grpc-encoding", "gzip") catch @panic("out of memory");
    {
        var p = payload(alloc, 271828);
        var expect = msgs.BoolValue{ .value = true };
        const req = msgs.SimpleRequest{ .response_size = 31415, .payload = &p, .expect_compressed = &expect };
        switch (client.unaryCall(&req, &md, null)) {
            .ok => |resp| util.check(resp.payload.?.body.len == 31415, "client_compressed_unary: body len"),
            .status => |st| util.checkFmt(false, "client_compressed_unary: status {d}", .{st.code}),
        }
        std.debug.print("interop case ok: client_compressed_unary\n", .{});
    }
    {
        const sizes = [_]i32{ 27182, 8, 1828, 45904 };
        const reqs = alloc.alloc(msgs.StreamingInputCallRequest, sizes.len) catch @panic("out of memory");
        const payloads = alloc.alloc(msgs.Payload, sizes.len) catch @panic("out of memory");
        var expect = msgs.BoolValue{ .value = true };
        var total: i32 = 0;
        for (sizes, 0..) |size, i| {
            payloads[i] = payload(alloc, @intCast(size));
            reqs[i] = .{ .payload = &payloads[i], .expect_compressed = &expect };
            total += size;
        }
        switch (client.streamingInputCall(reqs, &md, null)) {
            .ok => |resp| util.check(resp.aggregated_payload_size == total, "client_compressed_streaming: aggregated"),
            .status => |st| util.checkFmt(false, "client_compressed_streaming: status {d}", .{st.code}),
        }
        std.debug.print("interop case ok: client_compressed_streaming\n", .{});
    }
    {
        var p = payload(alloc, 271828);
        var compressed = msgs.BoolValue{ .value = true };
        const req = msgs.SimpleRequest{ .response_size = 31415, .payload = &p, .response_compressed = &compressed };
        switch (client.unaryCall(&req, null, null)) {
            .ok => |resp| util.check(resp.payload.?.body.len == 31415, "server_compressed_unary: body len"),
            .status => |st| util.checkFmt(false, "server_compressed_unary: status {d}", .{st.code}),
        }
        std.debug.print("interop case ok: server_compressed_unary\n", .{});
    }
    {
        const sizes = [_]i32{ 31415, 9, 2653, 58979 };
        const params = alloc.alloc(msgs.ResponseParameters, sizes.len) catch @panic("out of memory");
        var compressed = msgs.BoolValue{ .value = true };
        for (sizes, 0..) |size, i| {
            params[i] = .{ .size = size, .compressed = &compressed };
        }
        var p = payload(alloc, 0);
        const req = msgs.StreamingOutputCallRequest{ .response_parameters = params, .payload = &p };
        switch (client.streamingOutputCall(&req, null, null)) {
            .ok => |stream| {
                var s = stream;
                defer s.deinit();
                for (sizes) |size| {
                    switch (s.recv()) {
                        .message => |resp| util.check(resp.payload.?.body.len == @as(usize, @intCast(size)), "server_compressed_streaming: body len"),
                        else => util.check(false, "server_compressed_streaming: early end"),
                    }
                }
            },
            .status => |st| util.checkFmt(false, "server_compressed_streaming: status {d}", .{st.code}),
        }
        std.debug.print("interop case ok: server_compressed_streaming\n", .{});
    }
}

// ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
// report returns as the serialized OrcaLoadReport in the
// endpoint-load-metrics-bin trailer (base64 -bin value); OOB the
// value fed through FullDuplexCall comes back on the
// OpenRcaService StreamCoreMetrics stream.
fn runOrcaCases(alloc: std.mem.Allocator, channel: *grpcdc.channel.Channel, client: *TestServiceClient) void {
    var report = msgs.TestOrcaReport{
        .cpu_utilization = 0.8210,
        .memory_utilization = 0.5847,
        .request_cost = &.{.{ .key = "cost", .value = 3456.32 }},
        .utilization = &.{.{ .key = "util", .value = 0.30499 }},
    };
    const req = msgs.SimpleRequest{ .orca_per_query_report = &report };
    switch (channel.serverStream("/grpc.testing.TestService/UnaryCall", &req, null, null)) {
        .ok => |stream| {
            var s = stream;
            defer s.deinit();
            var resp = msgs.SimpleResponse{};
            switch (s.recvInto(&resp)) {
                .message => {},
                else => util.check(false, "orca_per_rpc: no response"),
            }
            var resp2 = msgs.SimpleResponse{};
            switch (s.recvInto(&resp2)) {
                .end => {},
                else => util.check(false, "orca_per_rpc: expected end"),
            }
            var encoded: ?[]const u8 = null;
            for (s.trailers) |pair| {
                if (std.mem.eql(u8, pair.key, "endpoint-load-metrics-bin")) encoded = pair.value;
            }
            util.check(encoded != null, "orca_per_rpc: no endpoint-load-metrics-bin trailer");
            const enc = encoded.?;
            const padded_len = (enc.len + 3) / 4 * 4;
            const padded = alloc.alloc(u8, padded_len) catch @panic("out of memory");
            defer alloc.free(padded);
            @memcpy(padded[0..enc.len], enc);
            @memset(padded[enc.len..], '=');
            const raw_len = std.base64.standard.Decoder.calcSizeForSlice(padded) catch @panic("bad base64");
            const raw = alloc.alloc(u8, raw_len) catch @panic("out of memory");
            defer alloc.free(raw);
            std.base64.standard.Decoder.decode(raw, padded) catch @panic("bad base64");
            var load_report = orca_msgs.OrcaLoadReport{};
            load_report.unmarshalDc(alloc, raw);
            var cost_ok = false;
            var util_ok = false;
            for (load_report.request_cost) |e| {
                if (std.mem.eql(u8, e.key, "cost") and e.value == 3456.32) cost_ok = true;
            }
            for (load_report.utilization) |e| {
                if (std.mem.eql(u8, e.key, "util") and e.value == 0.30499) util_ok = true;
            }
            util.check(load_report.cpu_utilization == 0.8210 and load_report.mem_utilization == 0.5847 and cost_ok and util_ok, "orca_per_rpc: report mismatch");
        },
        .status => |st| util.checkFmt(false, "orca_per_rpc: status {d}", .{st.code}),
    }
    std.debug.print("interop case ok: orca_per_rpc\n", .{});

    var oob_report = msgs.TestOrcaReport{
        .cpu_utilization = 0.9,
        .memory_utilization = 0.85,
        .utilization = &.{.{ .key = "util", .value = 0.5 }},
    };
    const feed_req = msgs.StreamingOutputCallRequest{ .orca_oob_report = &oob_report };
    switch (client.fullDuplexCall(&.{feed_req}, null, null)) {
        .ok => |stream| {
            var s = stream;
            defer s.deinit();
            switch (s.recv()) {
                .end => {},
                else => util.check(false, "orca_oob: feed did not complete"),
            }
        },
        .status => |st| util.checkFmt(false, "orca_oob feed: status {d}", .{st.code}),
    }
    var orca_client = orca_stub.OpenRcaServiceClient.init(channel);
    const metrics_req = orca_stub.OrcaLoadReportRequest{};
    switch (orca_client.streamCoreMetrics(&metrics_req, null, 30000)) {
        .ok => |stream| {
            var s = stream;
            defer s.deinit();
            var matched = false;
            var attempts: usize = 0;
            while (!matched and attempts < 30) : (attempts += 1) {
                switch (s.recv()) {
                    .message => |got| {
                        var util_ok = false;
                        for (got.utilization) |e| {
                            if (std.mem.eql(u8, e.key, "util") and e.value == 0.5) util_ok = true;
                        }
                        matched = got.cpu_utilization == 0.9 and got.mem_utilization == 0.85 and util_ok;
                    },
                    else => break,
                }
            }
            util.check(matched, "orca_oob: no matching OOB report");
        },
        .status => |st| util.checkFmt(false, "orca_oob: status {d}", .{st.code}),
    }
    std.debug.print("interop case ok: orca_oob\n", .{});
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
    runCases(alloc, &channel, &client, &unimpl);
    runCompressionCases(alloc, &client);
    runOrcaCases(alloc, &channel, &client);
    std.debug.print("TestInteropOracle OK\n", .{});
}
