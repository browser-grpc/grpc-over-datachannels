const std = @import("std");
const util = @import("test_util.zig");

const cases = [_][]const u8{
    "empty_unary",
    "large_unary",
    "client_streaming",
    "server_streaming",
    "ping_pong",
    "empty_stream",
    "custom_metadata",
    "status_code_and_message",
    "special_status_message",
    "unimplemented_method",
    "unimplemented_service",
    "cancel_after_begin",
    "cancel_after_first_response",
    "timeout_on_sleeping_server",
};

const java_only_cases = [_][]const u8{
    "cacheable_unary",
    "client_compressed_unary",
    "client_compressed_streaming",
    "server_compressed_unary",
    "server_compressed_streaming",
};

const go_only_cases = [_][]const u8{ "orca_per_rpc", "orca_oob" };

fn runClient(alloc: std.mem.Allocator, argv: []const []const u8) []const u8 {
    var child = util.spawn(alloc, argv) catch |err| {
        std.debug.print("spawn failed: {s}\n", .{@errorName(err)});
        util.check(false, "client spawn");
        return "";
    };
    var out_drain = util.Drain{};
    var err_drain = util.Drain{};
    util.startDrain(alloc, &out_drain, child.stdout.?);
    util.startDrain(alloc, &err_drain, child.stderr.?);
    const code = util.waitExit(&child, 120000);
    // Give drains a moment to flush.
    var waited: u64 = 0;
    while (waited < 5000 and !(out_drain.isDone() and err_drain.isDone())) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        waited += 10;
    }
    util.checkFmt(code == 0, "client exit {d}: {s}", .{ code, argv[0] });
    const out_text = std.fmt.allocPrint(alloc, "{s}{s}", .{ out_drain.text(), err_drain.text() }) catch "";
    return out_text;
}

/// Interop oracle, Direction B: the OFFICIAL interop clients
/// (grpc-java TestServiceClient, grpc-go interop-client) run the
/// canonical cases against the generated Zig TestService server
/// (examples/interop_server_stdio), reached over HTTP/2 through
/// oracle/bridge.mjs http2-to-dc. Skips when an oracle binary or
/// Node is unavailable. Mirrors
/// java/tests/TestInteropServerOracle.java.
pub fn testInteropServerOracle(alloc: std.mem.Allocator) void {
    const root_path = util.root(alloc);
    const cp = util.javaClasspath(alloc, root_path) orelse {
        std.debug.print("TestInteropServerOracle SKIP (java oracle not built)\n", .{});
        return;
    };
    const server_bin = std.fmt.allocPrint(alloc, "{s}/zig/build/bin/interop_server_stdio", .{root_path}) catch unreachable;
    if (!util.fileExists(server_bin)) {
        std.debug.print("TestInteropServerOracle SKIP (zig server not built)\n", .{});
        return;
    }
    const port = util.freePort();
    const port_str = std.fmt.allocPrint(alloc, "{d}", .{port}) catch unreachable;
    const bridge_path = std.fmt.allocPrint(alloc, "{s}/oracle/bridge.mjs", .{root_path}) catch unreachable;
    var bridge = util.spawn(alloc, &.{ "node", bridge_path, "http2-to-dc", "--port", port_str, "--target-cmd", server_bin }) catch {
        std.debug.print("TestInteropServerOracle SKIP (bridge did not start)\n", .{});
        return;
    };
    defer util.killChild(&bridge);
    var bridge_err = util.Drain{};
    util.startDrain(alloc, &bridge_err, bridge.stderr.?);
    if (!util.waitReady(&bridge_err, "listening", 60000)) {
        std.debug.print("TestInteropServerOracle SKIP (bridge did not start)\n", .{});
        return;
    }
    for (cases ++ java_only_cases) |test_case| {
        const out_text = runClient(alloc, &.{
            "java", "-cp", cp, "io.grpc.testing.integration.TestServiceClient",
            "--server_host=127.0.0.1",
            std.fmt.allocPrint(alloc, "--server_port={d}", .{port}) catch unreachable,
            std.fmt.allocPrint(alloc, "--test_case={s}", .{test_case}) catch unreachable,
            "--use_tls=false",
        });
        util.check(std.mem.indexOf(u8, out_text, "Test completed.") != null, "java case output");
        std.debug.print("interop B case ok: {s} (java client)\n", .{test_case});
    }
    const go_client = std.fmt.allocPrint(alloc, "{s}/oracle/go-interop/interop-client", .{root_path}) catch unreachable;
    if (!util.fileExists(go_client)) {
        std.debug.print("TestInteropServerOracle GO SKIP (go client not built)\n", .{});
    } else {
        for (cases ++ go_only_cases) |test_case| {
            if (std.mem.startsWith(u8, test_case, "orca")) {
                _ = runClient(alloc, &.{
                    go_client,
                    "-server_host", "127.0.0.1",
                    "-server_port", port_str,
                    "-test_case", test_case,
                    "-service_config_json",
                    "{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}",
                });
            } else {
                _ = runClient(alloc, &.{
                    go_client,
                    "-server_host", "127.0.0.1",
                    "-server_port", port_str,
                    "-test_case", test_case,
                });
            }
            std.debug.print("interop B case ok: {s} (go client)\n", .{test_case});
        }
    }
    util.killChild(&bridge);
    std.debug.print("TestInteropServerOracle OK\n", .{});
}
