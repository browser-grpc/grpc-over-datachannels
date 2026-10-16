//! Browser test entry point: runs the four Echo call shapes
//! through the generated Zig WASM facade (echo_wasm_dc.zig)
//! over the JS grpc-dc bridge, then reports a JSON summary
//! via the on_result import. Callback-chained throughout —
//! wasm32-freestanding has no threads to block on. Mirrors
//! wasm/go/cmd/echo_wasm/main.go.

const std = @import("std");
const bridge_mod = @import("bridge.zig");
const echo = @import("echo_wasm_dc.zig");

extern "env" fn on_result(ptr: [*]const u8, len: usize) void;
extern "env" fn on_error(ptr: [*]const u8, len: usize) void;

const alloc = std.heap.wasm_allocator;

var bridge: bridge_mod.Bridge = undefined;
var client: echo.EchoClient = undefined;

const State = struct {
    unary: []u8 = "",
    ticks: std.ArrayList(i32) = .empty,
    joined: []u8 = "",
    echoed: std.ArrayList([]u8) = .empty,
};

var state: State = .{};

fn fail(st: echo.Status) void {
    const msg = std.fmt.allocPrint(alloc, "grpc status {d}: {s}", .{ st.code, st.message }) catch "out of memory";
    on_error(msg.ptr, msg.len);
}

fn req(message: []const u8, count: i32) echo.EchoRequest {
    return .{ .message = message, .count = count };
}

export fn run_echo_client() void {
    bridge = bridge_mod.Bridge.init(alloc);
    client = echo.EchoClient.init(&bridge);
    client.unary(&req("hello", 0), &state, onUnary);
}

fn onUnary(ctx: *anyopaque, result: echo.CallResult(echo.EchoResponse)) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    switch (result) {
        .status => |s| fail(s),
        .ok => |resp| {
            st.unary = alloc.dupe(u8, resp.message) catch "";
            client.serverStream(&req("tick", 3), st, onTick, onStreamDone);
        },
    }
}

fn onTick(ctx: *anyopaque, resp: echo.EchoResponse) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    st.ticks.append(alloc, resp.index) catch {};
}

fn onStreamDone(ctx: *anyopaque, st: echo.Status) void {
    const state_ptr: *State = @ptrCast(@alignCast(ctx));
    if (!st.isOk()) return fail(st);
    client.clientStream(&.{ req("a", 0), req("b", 0) }, state_ptr, onJoined);
}

fn onJoined(ctx: *anyopaque, result: echo.CallResult(echo.EchoResponse)) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    switch (result) {
        .status => |s| fail(s),
        .ok => |resp| {
            st.joined = alloc.dupe(u8, resp.message) catch "";
            client.bidi(&.{ req("x", 0), req("y", 0) }, st, onEchoed, onBidiDone);
        },
    }
}

fn onEchoed(ctx: *anyopaque, resp: echo.EchoResponse) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    const msg = alloc.dupe(u8, resp.message) catch return;
    st.echoed.append(alloc, msg) catch {};
}

fn onBidiDone(ctx: *anyopaque, st: echo.Status) void {
    const state_ptr: *State = @ptrCast(@alignCast(ctx));
    if (!st.isOk()) return fail(st);
    const Result = struct {
        unary: []const u8,
        ticks: []const i32,
        joined: []const u8,
        echoed: []const []const u8,
    };
    const echoed: []const []const u8 = @ptrCast(state_ptr.echoed.items);
    const json = std.json.Stringify.valueAlloc(alloc, Result{
        .unary = state_ptr.unary,
        .ticks = state_ptr.ticks.items,
        .joined = state_ptr.joined,
        .echoed = echoed,
    }, .{}) catch {
        on_error("out of memory".ptr, "out of memory".len);
        return;
    };
    on_result(json.ptr, json.len);
}
