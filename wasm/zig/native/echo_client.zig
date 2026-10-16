//! Browser test entry point (native runtime): runs the four
//! Echo call shapes with the *native* generated Zig client
//! (zig/examples/echo_grpc_dc.zig) over the real grpcdc
//! channel/endpoint runtime on a DataChannel transport, in a
//! Web Worker. The endpoint runs in inline pump mode
//! (try_recv transport), so the ordinary blocking client code
//! below drives itself. Mirrors wasm/rust's echo client.

const std = @import("std");
const grpcdc = @import("grpcdc");
const stubs = @import("echo_stub");
const dc_transport = @import("./dc_transport.zig");

extern "env" fn on_result(ptr: [*]const u8, len: usize) void;
extern "env" fn on_error(ptr: [*]const u8, len: usize) void;

const alloc = std.heap.wasm_allocator;

fn req(message: []const u8, count: i32) stubs.EchoRequest {
    return .{ .message = message, .count = count };
}

fn fail(st: stubs.Status) void {
    const msg = std.fmt.allocPrint(alloc, "grpc status {d}: {s}", .{ st.code, st.message }) catch "out of memory";
    on_error(msg.ptr, msg.len);
}

export fn run_echo_client() void {
    var dc = dc_transport.DcTransport{};
    var channel = grpcdc.channel.Channel.init(alloc, dc.transport());
    defer channel.deinit();
    var client = stubs.EchoClient.init(&channel);

    const unary_resp = switch (client.unary(&req("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| return fail(st),
    };
    const unary_msg = alloc.dupe(u8, unary_resp.message) catch return fail(stubs.Status.init(13, "out of memory"));

    var stream = switch (client.serverStream(&req("tick", 3), null, null)) {
        .ok => |s| s,
        .status => |st| return fail(st),
    };
    defer stream.deinit();
    var ticks: std.ArrayList(i32) = .empty;
    defer ticks.deinit(alloc);
    while (true) {
        switch (stream.recv()) {
            .message => |resp| ticks.append(alloc, resp.index) catch return fail(stubs.Status.init(13, "out of memory")),
            .end => break,
            .status => |st| return fail(st),
        }
    }

    const joined = switch (client.clientStream(&.{ req("a", 0), req("b", 0) }, null, null)) {
        .ok => |r| r,
        .status => |st| return fail(st),
    };
    const joined_msg = alloc.dupe(u8, joined.message) catch return fail(stubs.Status.init(13, "out of memory"));

    var bidi = switch (client.bidi(&.{ req("x", 0), req("y", 0) }, null, null)) {
        .ok => |s| s,
        .status => |st| return fail(st),
    };
    defer bidi.deinit();
    var echoed: std.ArrayList([]u8) = .empty;
    defer echoed.deinit(alloc);
    while (true) {
        switch (bidi.recv()) {
            .message => |resp| {
                const msg = alloc.dupe(u8, resp.message) catch return fail(stubs.Status.init(13, "out of memory"));
                echoed.append(alloc, msg) catch return fail(stubs.Status.init(13, "out of memory"));
            },
            .end => break,
            .status => |st| return fail(st),
        }
    }

    const Result = struct {
        unary: []const u8,
        ticks: []const i32,
        joined: []const u8,
        echoed: []const []const u8,
    };
    const echoed_view: []const []const u8 = @ptrCast(echoed.items);
    const json = std.json.Stringify.valueAlloc(alloc, Result{
        .unary = unary_msg,
        .ticks = ticks.items,
        .joined = joined_msg,
        .echoed = echoed_view,
    }, .{}) catch return fail(stubs.Status.init(13, "out of memory"));
    on_result(json.ptr, json.len);
}
