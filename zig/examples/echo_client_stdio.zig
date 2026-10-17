const std = @import("std");
const grpcdc = @import("grpcdc");
const channel_mod = grpcdc.channel;
const stdio_mod = @import("stdio_transport.zig");
const stubs = @import("echo_grpc_dc.zig");
const messages = @import("echo_messages.zig");

/// Interop harness: the Zig echo client over stdio. Prints one line
/// per call shape to stderr (stdout carries frames) and exits
/// non-zero on any failure.
pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();
    if (!run(alloc)) {
        std.process.exit(1);
    }
}

fn req(message: []const u8, count: i32) messages.EchoRequest {
    return .{ .message = message, .count = count };
}

fn run(alloc: std.mem.Allocator) bool {
    var transport = stdio_mod.StdioTransport.init(alloc, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    var channel = channel_mod.Channel.init(alloc, transport.transport());
    defer channel.deinit();
    var client = stubs.EchoClient.init(&channel);

    const unary_resp = switch (client.unary(&req("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| {
            std.debug.print("unary status: {d} {s}\n", .{ st.code, st.message });
            return false;
        },
    };
    std.debug.print("unary={s}\n", .{unary_resp.message});

    var stream = switch (client.serverStream(&req("tick", 3), null, null)) {
        .ok => |s| s,
        .status => |st| {
            std.debug.print("server_stream status: {d} {s}\n", .{ st.code, st.message });
            return false;
        },
    };
    defer stream.deinit();
    var ticks: std.ArrayList(u8) = .empty;
    defer ticks.deinit(alloc);
    var first = true;
    while (true) {
        switch (stream.recv()) {
            .message => |resp| {
                if (!first) ticks.appendSlice(alloc, ",") catch return false;
                first = false;
                ticks.print(alloc, "{s}#{d}", .{ resp.message, resp.index }) catch return false;
            },
            .end => break,
            .status => |st| {
                std.debug.print("server_stream recv status: {d} {s}\n", .{ st.code, st.message });
                return false;
            },
        }
    }
    std.debug.print("server_stream={s}\n", .{ticks.items});

    const joined = switch (client.clientStream(&.{ req("a", 0), req("b", 0), req("c", 0) }, null, null)) {
        .ok => |r| r,
        .status => |st| {
            std.debug.print("client_stream status: {d} {s}\n", .{ st.code, st.message });
            return false;
        },
    };
    std.debug.print("client_stream={s}\n", .{joined.message});

    var bidi = switch (client.bidi(&.{ req("x", 0), req("y", 0) }, null, null)) {
        .ok => |s| s,
        .status => |st| {
            std.debug.print("bidi status: {d} {s}\n", .{ st.code, st.message });
            return false;
        },
    };
    defer bidi.deinit();
    var echoed: std.ArrayList(u8) = .empty;
    defer echoed.deinit(alloc);
    var bfirst = true;
    while (true) {
        switch (bidi.recv()) {
            .message => |resp| {
                if (!bfirst) echoed.appendSlice(alloc, ",") catch return false;
                bfirst = false;
                echoed.appendSlice(alloc, resp.message) catch return false;
            },
            .end => break,
            .status => |st| {
                std.debug.print("bidi recv status: {d} {s}\n", .{ st.code, st.message });
                return false;
            },
        }
    }
    std.debug.print("bidi={s}\n", .{echoed.items});

    var md_map = grpcdc.transport.Metadata.init(alloc);
    defer md_map.deinit();
    md_map.put("x-echo", "meta") catch return false;
    switch (client.unary(&req("hello", 0), &md_map, null)) {
        .ok => |md_resp| std.debug.print("metadata={s}\n", .{md_resp.message}),
        .status => |st| {
            std.debug.print("metadata status: {d} {s}\n", .{ st.code, st.message });
            return false;
        },
    }

    var slow_req = req("slow", 0);
    slow_req.delay_ms = 400;
    switch (client.unary(&slow_req, null, 50)) {
        .ok => std.debug.print("deadline=no error\n", .{}),
        .status => |st| std.debug.print("deadline={d}\n", .{st.code}),
    }

    switch (client.unary(&req("fail", 0), null, null)) {
        .ok => {
            std.debug.print("error_case=no error\n", .{});
            return false;
        },
        .status => |st| {
            std.debug.print("error_case={s}: {s}\n", .{ grpcdc.wire.statusName(alloc, st.code), st.message });
        },
    }
    return true;
}
