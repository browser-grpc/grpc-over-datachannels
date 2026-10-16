const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const EchoRequest = examples.echo_messages.EchoRequest;

fn req(message: []const u8, count: i32) EchoRequest {
    return .{ .message = message, .count = count };
}

fn buildGo(alloc: std.mem.Allocator, root_path: []const u8, output: []const u8, pkg: []const u8) bool {
    const go_dir = std.fmt.allocPrint(alloc, "{s}/go", .{root_path}) catch return false;
    var child = std.process.Child.init(&.{ "go", "build", "-o", output, pkg }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = go_dir;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn pumpFn(from_fd: std.posix.fd_t, to_fd: std.posix.fd_t) void {
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = std.posix.read(from_fd, &buf) catch return;
        if (n == 0) return;
        var written: usize = 0;
        while (written < n) {
            written += std.posix.write(to_fd, buf[written..n]) catch return;
        }
    }
}

/// Interop: the Zig runtime against the Go stdio harnesses (cross-
/// language wire compatibility). Skips when Go is unavailable.
pub fn testInterop(alloc: std.mem.Allocator) void {
    const root_path = util.root(alloc);
    const tmp = "/tmp/grpcdc_zig_interop";
    std.fs.cwd().makePath(tmp) catch {};
    const server_bin = tmp ++ "/echo_server_stdio";
    if (!buildGo(alloc, root_path, server_bin, "./examples/echo_server_stdio")) {
        std.debug.print("TestInterop SKIP (no go)\n", .{});
        return;
    }

    var server = util.spawn(alloc, &.{server_bin}) catch {
        std.debug.print("TestInterop SKIP (go server did not start)\n", .{});
        return;
    };
    var server_err = util.Drain{};
    util.startDrain(alloc, &server_err, server.stderr.?);
    {
        var transport = examples.stdio_transport.StdioTransport.init(alloc, server.stdout.?.handle, server.stdin.?.handle);
        var channel = grpcdc.channel.Channel.init(alloc, transport.transport());
        defer channel.deinit();
        var client = examples.echo_grpc_dc.EchoClient.init(&channel);

        const unary = switch (client.unary(&req("hello", 0), null, null)) {
            .ok => |r| r,
            .status => |st| {
                util.checkFmt(false, "unary status {d}", .{st.code});
                unreachable;
            },
        };
        util.check(std.mem.eql(u8, unary.message, "echo: hello"), "unary");

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
        util.check(n == 3 and indexes[0] == 0 and indexes[1] == 1 and indexes[2] == 2, "server stream");

        const joined = switch (client.clientStream(&.{ req("a", 0), req("b", 0), req("c", 0) }, null, null)) {
            .ok => |r| r,
            .status => |st| {
                util.checkFmt(false, "clientStream status {d}", .{st.code});
                unreachable;
            },
        };
        util.check(std.mem.eql(u8, joined.message, "a+b+c"), "client stream");

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
                .status => break,
            }
        }
        util.check(m == 2 and std.mem.eql(u8, echoed[0], "x") and std.mem.eql(u8, echoed[1], "y"), "bidi");

        switch (client.unary(&req("fail", 0), null, null)) {
            .ok => util.check(false, "fail should fail"),
            .status => |st| util.check(st.code == 3, "fail status"),
        }
    }
    util.killChild(&server);

    // Reverse: Go client harness against the Zig stdio server.
    const client_bin = tmp ++ "/echo_client_stdio";
    if (!buildGo(alloc, root_path, client_bin, "./examples/echo_client_stdio")) {
        std.debug.print("TestInterop partial SKIP (client build)\n", .{});
        return;
    }
    const zig_server = std.fmt.allocPrint(alloc, "{s}/zig/build/bin/echo_server_stdio", .{root_path}) catch unreachable;
    if (!util.fileExists(zig_server)) {
        std.debug.print("TestInterop partial SKIP (zig server not built)\n", .{});
        return;
    }
    var zig = util.spawn(alloc, &.{zig_server}) catch return;
    var go_client = util.spawn(alloc, &.{client_bin}) catch return;
    var zig_err = util.Drain{};
    var go_err = util.Drain{};
    util.startDrain(alloc, &zig_err, zig.stderr.?);
    util.startDrain(alloc, &go_err, go_client.stderr.?);
    const pump_a = std.Thread.spawn(.{}, pumpFn, .{ go_client.stdout.?.handle, zig.stdin.?.handle }) catch unreachable;
    const pump_b = std.Thread.spawn(.{}, pumpFn, .{ zig.stdout.?.handle, go_client.stdin.?.handle }) catch unreachable;
    const exit_code = util.waitExit(&go_client, 60000);
    util.check(exit_code == 0, "go client harness exit");
    util.killChild(&zig);
    util.killChild(&go_client);
    pump_a.detach();
    pump_b.detach();
    while (!go_err.isDone()) std.Thread.sleep(10 * std.time.ns_per_ms);
    const err_text = go_err.text();
    util.check(std.mem.indexOf(u8, err_text, "unary=echo: hello") != null, "go client unary");
    util.check(std.mem.indexOf(u8, err_text, "server_stream=tick#0,tick#1,tick#2") != null, "go client stream");
    util.check(std.mem.indexOf(u8, err_text, "client_stream=a+b+c") != null, "go client client-stream");
    util.check(std.mem.indexOf(u8, err_text, "bidi=x,y") != null, "go client bidi");
    std.debug.print("TestInterop OK\n", .{});
}
