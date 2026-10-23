//! Browser test entry point (facade server role): registers
//! the generated Zig WASM facade server (echo_wasm_dc.zig)
//! whose typed handlers run here in WASM; the page's JS
//! server bridge owns the wire. The Node test's JS client
//! drives the four call shapes plus a deadline the slow
//! handler must miss. Mirrors wasm/kotlin/echo_server_facade.kt.

const std = @import("std");
const bridge_mod = @import("bridge.zig");
const echo = @import("echo_wasm_dc.zig");

extern "env" fn js_now_ms() f64;

const alloc = std.heap.wasm_allocator;
const Status = echo.Status;

fn delayMs(ms: i32) void {
    if (ms <= 0) return;
    const until = js_now_ms() + @as(f64, @floatFromInt(ms));
    while (js_now_ms() < until) {}
}

fn unaryImpl(_: *anyopaque, req: *const echo.EchoRequest, md: []const bridge_mod.MdPair) echo.CallResult(echo.EchoResponse) {
    delayMs(req.delay_ms);
    if (std.mem.eql(u8, req.message, "fail")) {
        return .{ .status = Status.init(3, "asked to fail") };
    }
    const marker = bridge_mod.metadataGet(md, "x-echo") orelse "";
    const message = if (marker.len > 0)
        std.fmt.allocPrint(alloc, "echo: {s} [{s}]", .{ req.message, marker }) catch return .{ .status = Status.init(13, "out of memory") }
    else
        std.fmt.allocPrint(alloc, "echo: {s}", .{req.message}) catch return .{ .status = Status.init(13, "out of memory") };
    return .{ .ok = .{ .message = message, .index = 0 } };
}

fn serverStreamImpl(_: *anyopaque, req: *const echo.EchoRequest, _: []const bridge_mod.MdPair, sink: *echo.ServerSink) Status {
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(3, "asked to fail");
    }
    var i: i32 = 0;
    while (i < req.count) : (i += 1) {
        var resp = echo.EchoResponse{ .message = req.message, .index = i };
        const st = sink.send(&resp);
        if (!st.isOk()) return st;
    }
    return Status.ok();
}

fn clientStreamImpl(_: *anyopaque, reqs: []const echo.EchoRequest, _: []const bridge_mod.MdPair) echo.CallResult(echo.EchoResponse) {
    var joined: std.ArrayList(u8) = .empty;
    for (reqs, 0..) |*req, i| {
        if (std.mem.eql(u8, req.message, "fail")) {
            return .{ .status = Status.init(3, "asked to fail") };
        }
        if (i > 0) joined.append(alloc, '+') catch return .{ .status = Status.init(13, "out of memory") };
        joined.appendSlice(alloc, req.message) catch return .{ .status = Status.init(13, "out of memory") };
    }
    return .{ .ok = .{ .message = joined.items, .index = @intCast(reqs.len) } };
}

fn bidiImpl(_: *anyopaque, reqs: []const echo.EchoRequest, _: []const bridge_mod.MdPair, sink: *echo.ServerSink) Status {
    for (reqs, 0..) |*req, i| {
        if (std.mem.eql(u8, req.message, "fail")) {
            return Status.init(3, "asked to fail");
        }
        var resp = echo.EchoResponse{ .message = req.message, .index = @intCast(i) };
        const st = sink.send(&resp);
        if (!st.isOk()) return st;
    }
    return Status.ok();
}

var impl = echo.EchoServer{
    .ctx = undefined,
    .unary_fn = unaryImpl,
    .serverStream_fn = serverStreamImpl,
    .clientStream_fn = clientStreamImpl,
    .bidi_fn = bidiImpl,
};

export fn run_echo_server() void {
    _ = bridge_mod.Bridge.init(alloc);
    echo.registerEchoServer(&impl);
}
