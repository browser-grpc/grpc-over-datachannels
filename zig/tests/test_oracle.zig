const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const runner = @import("scenario_runner.zig");
const util = @import("test_util.zig");

/// Oracle: official grpc-java, bridged over TCP<->DataChannel by
/// oracle/bridge.mjs, must agree with the Zig runtime on every case
/// of the generated scenario driver. Skips when the Java oracle or
/// Node bridge are unavailable (Dockerfile.ci provides both).
pub fn testOracle(alloc: std.mem.Allocator) void {
    const root_path = util.root(alloc);
    const cp = util.javaClasspath(alloc, root_path) orelse {
        std.debug.print("TestOracle SKIP (java oracle not built)\n", .{});
        return;
    };

    // Direction A: this client -> bridge -> official server.
    const port = util.freePort();
    const port_str = std.fmt.allocPrint(alloc, "{d}", .{port}) catch unreachable;
    var server = util.spawn(alloc, &.{ "java", "-cp", cp, "dc.oracle.OracleServer", port_str }) catch {
        std.debug.print("TestOracle SKIP (oracle server did not start)\n", .{});
        return;
    };
    var server_err = util.Drain{};
    util.startDrain(alloc, &server_err, server.stderr.?);
    if (!util.waitReady(&server_err, "READY", 60000)) {
        util.killChild(&server);
        std.debug.print("TestOracle SKIP (oracle server did not start)\n", .{});
        return;
    }
    const grpc_addr = std.fmt.allocPrint(alloc, "127.0.0.1:{d}", .{port}) catch unreachable;
    const bridge_path = std.fmt.allocPrint(alloc, "{s}/oracle/bridge.mjs", .{root_path}) catch unreachable;
    var bridge = util.spawn(alloc, &.{ "node", bridge_path, "dc-to-http2", "--grpc", grpc_addr }) catch {
        util.killChild(&server);
        std.debug.print("TestOracle SKIP (bridge did not start)\n", .{});
        return;
    };
    var bridge_err = util.Drain{};
    util.startDrain(alloc, &bridge_err, bridge.stderr.?);
    {
        var transport = examples.stdio_transport.StdioTransport.init(alloc, bridge.stdout.?.handle, bridge.stdin.?.handle);
        var channel = grpcdc.channel.Channel.init(alloc, transport.transport());
        defer channel.deinit();
        var client = examples.echo_grpc_dc.EchoClient.init(&channel);
        runner.runScenarios(alloc, &client);
    }
    util.killChild(&bridge);
    util.killChild(&server);

    // Direction B: official client -> bridge -> this runtime's server.
    const server_bin = std.fmt.allocPrint(alloc, "{s}/zig/build/bin/echo_server_stdio", .{root_path}) catch unreachable;
    if (!util.fileExists(server_bin)) {
        std.debug.print("TestOracle SKIP (zig server not built)\n", .{});
        return;
    }
    const port_b = util.freePort();
    const port_b_str = std.fmt.allocPrint(alloc, "{d}", .{port_b}) catch unreachable;
    var bridge_b = util.spawn(alloc, &.{ "node", bridge_path, "http2-to-dc", "--port", port_b_str, "--target-cmd", server_bin }) catch {
        std.debug.print("TestOracle SKIP (bridge B did not start)\n", .{});
        return;
    };
    var bridge_b_err = util.Drain{};
    util.startDrain(alloc, &bridge_b_err, bridge_b.stderr.?);
    if (!util.waitReady(&bridge_b_err, "listening", 60000)) {
        util.killChild(&bridge_b);
        std.debug.print("TestOracle SKIP (bridge did not start)\n", .{});
        return;
    }
    const scenarios_path = std.fmt.allocPrint(alloc, "{s}/fixtures/oracle_scenarios.txt", .{root_path}) catch unreachable;
    var client_proc = util.spawn(alloc, &.{ "java", "-cp", cp, "dc.oracle.OracleClient", port_b_str, scenarios_path }) catch {
        util.killChild(&bridge_b);
        std.debug.print("TestOracle SKIP (oracle client did not start)\n", .{});
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
    std.debug.print("TestOracle OK\n", .{});
}
