const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const runner = @import("scenario_runner.zig");
const util = @import("test_util.zig");

const dynamic = grpcdc.dynamic;

fn loadModel(alloc: std.mem.Allocator, root_path: []const u8) ?*dynamic.FileModel {
    const path = std.fmt.allocPrint(alloc, "{s}/fixtures/echo_descriptor_set.bin", .{root_path}) catch return null;
    const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 24) catch return null;
    return dynamic.parseDescriptorSet(alloc, data);
}

/// Dynamic (descriptor-driven) runtime: schemas consumed as data at
/// runtime, no generated stubs. Loopback plus the official grpc-java
/// oracle in both directions (the oracle is the runtime test bed).
pub fn testDynamic(alloc: std.mem.Allocator) void {
    const root_path = util.root(alloc);
    const model = loadModel(alloc, root_path) orelse {
        std.debug.print("TestDynamic SKIP (descriptor fixture missing)\n", .{});
        return;
    };

    // Generic codec + unknown-field retention round trip.
    const request_type = model.message(".echo.EchoRequest").?;
    const payload = [_]u8{ 0x0a, 0x02, 0x68, 0x69, 0x10, 0x02, 0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, 0x78 };
    const decoded = dynamic.decodeGeneric(alloc, request_type, &payload, model);
    util.check(decoded.unknown.items.len == 2, "unknown retained");
    const reencoded = switch (dynamic.encodeGeneric(alloc, request_type, decoded, model)) {
        .ok => |b| b,
        .status => |st| {
            util.checkFmt(false, "encode status {d}", .{st.code});
            unreachable;
        },
    };
    util.check(std.mem.eql(u8, reencoded, &payload), "unknown round trip");

    // Loopback: dynamic client against dynamic server.
    var pair = grpcdc.memory_transport.memoryTransportPair(alloc);
    defer pair.deinit(alloc);
    var loopback_server = grpcdc.server.Server.init(alloc);
    defer loopback_server.deinit();
    dynamic.registerDynamicService(&loopback_server, model, "echo.Echo", &examples.dynamic_echo_service.dynamic_echo_handler);
    _ = loopback_server.serveTransport(grpcdc.memory_transport.transportOf(pair.end_b));
    var channel = grpcdc.channel.Channel.init(alloc, grpcdc.memory_transport.transportOf(pair.end_a));
    defer channel.deinit();
    var dyn_client = dynamic.DynamicClient.init(&channel, model);
    runner.runDynamicScenarios(alloc, &dyn_client, model);

    const cp = util.javaClasspath(alloc, root_path) orelse {
        std.debug.print("TestDynamic OK (loopback; oracle skipped)\n", .{});
        return;
    };

    // Direction A: dynamic client -> bridge -> official server.
    const port = util.freePort();
    const port_str = std.fmt.allocPrint(alloc, "{d}", .{port}) catch unreachable;
    var server = util.spawn(alloc, &.{ "java", "-cp", cp, "dc.oracle.OracleServer", port_str }) catch {
        std.debug.print("TestDynamic SKIP (oracle server did not start)\n", .{});
        return;
    };
    var server_err = util.Drain{};
    util.startDrain(alloc, &server_err, server.stderr.?);
    if (!util.waitReady(&server_err, "READY", 60000)) {
        util.killChild(&server);
        std.debug.print("TestDynamic SKIP (oracle server did not start)\n", .{});
        return;
    }
    const grpc_addr = std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port}) catch unreachable;
    const bridge_path = std.fmt.allocPrint(alloc, "{s}/oracle/bridge.mjs", .{root_path}) catch unreachable;
    var bridge = util.spawn(alloc, &.{ "node", bridge_path, "dc-to-http2", "--grpc", grpc_addr }) catch {
        util.killChild(&server);
        std.debug.print("TestDynamic SKIP (bridge did not start)\n", .{});
        return;
    };
    var bridge_err = util.Drain{};
    util.startDrain(alloc, &bridge_err, bridge.stderr.?);
    {
        var transport = examples.stdio_transport.StdioTransport.init(alloc, bridge.stdout.?.handle, bridge.stdin.?.handle);
        var bridge_channel = grpcdc.channel.Channel.init(alloc, transport.transport());
        defer bridge_channel.deinit();
        var client = dynamic.DynamicClient.init(&bridge_channel, model);
        runner.runDynamicScenarios(alloc, &client, model);
    }
    util.killChild(&bridge);
    util.killChild(&server);

    // Direction B: official client -> bridge -> dynamic server.
    const server_bin = std.fmt.allocPrint(alloc, "{s}/zig/build/bin/dynamic_echo_server_stdio", .{root_path}) catch unreachable;
    if (!util.fileExists(server_bin)) {
        std.debug.print("TestDynamic SKIP (zig dynamic server not built)\n", .{});
        return;
    }
    const port_b = util.freePort();
    const port_b_str = std.fmt.allocPrint(alloc, "{d}", .{port_b}) catch unreachable;
    var bridge_b = util.spawn(alloc, &.{ "node", bridge_path, "http2-to-dc", "--port", port_b_str, "--target-cmd", server_bin }) catch {
        std.debug.print("TestDynamic SKIP (bridge B did not start)\n", .{});
        return;
    };
    var bridge_b_err = util.Drain{};
    util.startDrain(alloc, &bridge_b_err, bridge_b.stderr.?);
    if (!util.waitReady(&bridge_b_err, "listening", 60000)) {
        util.killChild(&bridge_b);
        std.debug.print("TestDynamic SKIP (bridge did not start)\n", .{});
        return;
    }
    const scenarios_path = std.fmt.allocPrint(alloc, "{s}/fixtures/oracle_scenarios.txt", .{root_path}) catch unreachable;
    var client_proc = util.spawn(alloc, &.{ "java", "-cp", cp, "dc.oracle.OracleClient", port_b_str, scenarios_path }) catch {
        util.killChild(&bridge_b);
        std.debug.print("TestDynamic SKIP (oracle client did not start)\n", .{});
        return;
    };
    var client_out = util.Drain{};
    var client_err = util.Drain{};
    util.startDrain(alloc, &client_out, client_proc.stdout.?);
    util.startDrain(alloc, &client_err, client_proc.stderr.?);
    const exit_code = util.waitExit(&client_proc, 120000);
    util.check(exit_code == 0, "oracle client failed");
    while (!client_out.isDone()) std.Thread.sleep(10 * std.time.ns_per_ms);
    util.check(std.mem.indexOf(u8, client_out.text(), "ORACLE CLIENT: ALL OK") != null, "oracle client output");
    util.killChild(&bridge_b);
    std.debug.print("TestDynamic OK\n", .{});
}
