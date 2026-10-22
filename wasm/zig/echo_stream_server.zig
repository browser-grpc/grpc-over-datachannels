//! Browser test entry point (facade stream server role):
//! registers the generated incremental EchoStreamServer whose
//! handlers are fed one request at a time through the
//! serve_*Start/Feed/End exports; the page's JS server bridge
//! owns the wire via registerClientStreamInc/registerBidiInc.
//! Bidi answers each request as it lands (ping-pong proof).

const std = @import("std");
const bridge_mod = @import("bridge.zig");
const echo = @import("echo_wasm_dc.zig");

const alloc = std.heap.wasm_allocator;
const Status = echo.Status;

const CallState = struct {
    parts: std.ArrayList([]u8) = .empty,
    index: i32 = 0,
    failed: bool = false,
};

var states: std.AutoHashMap(u32, *CallState) = undefined;
var states_ready = false;

fn stateFor(call_id: u32) *CallState {
    if (!states_ready) {
        states = std.AutoHashMap(u32, *CallState).init(alloc);
        states_ready = true;
    }
    if (states.get(call_id)) |state| return state;
    const state = alloc.create(CallState) catch @panic("oom");
    state.* = .{};
    states.put(call_id, state) catch @panic("oom");
    return state;
}

fn dropState(call_id: u32) void {
    if (states.fetchRemove(call_id)) |entry| {
        for (entry.value.parts.items) |part| alloc.free(part);
        entry.value.parts.deinit(alloc);
        alloc.destroy(entry.value);
    }
}

fn clientStreamBegin(_: *anyopaque, call_id: u32, _: []const bridge_mod.MdPair) void {
    _ = stateFor(call_id);
}

fn clientStreamRequest(_: *anyopaque, call_id: u32, req: *const echo.EchoRequest) void {
    const state = stateFor(call_id);
    if (std.mem.eql(u8, req.message, "fail")) {
        state.failed = true;
        return;
    }
    const copy = alloc.dupe(u8, req.message) catch return;
    state.parts.append(alloc, copy) catch alloc.free(copy);
}

fn clientStreamEnd(_: *anyopaque, call_id: u32) echo.CallResult(echo.EchoResponse) {
    const state = stateFor(call_id);
    if (state.failed) {
        dropState(call_id);
        return .{ .status = Status.init(3, "asked to fail") };
    }
    var joined: std.ArrayList(u8) = .empty;
    for (state.parts.items, 0..) |part, i| {
        if (i > 0) joined.append(alloc, '+') catch return .{ .status = Status.init(13, "out of memory") };
        joined.appendSlice(alloc, part) catch return .{ .status = Status.init(13, "out of memory") };
    }
    const count: i32 = @intCast(state.parts.items.len);
    dropState(call_id);
    return .{ .ok = .{ .message = joined.items, .index = count } };
}

fn bidiBegin(_: *anyopaque, call_id: u32, _: []const bridge_mod.MdPair) void {
    _ = stateFor(call_id);
}

fn bidiRequest(_: *anyopaque, call_id: u32, req: *const echo.EchoRequest, sink: *echo.ServerSink) Status {
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(3, "asked to fail");
    }
    const state = stateFor(call_id);
    var resp = echo.EchoResponse{ .message = req.message, .index = state.index };
    state.index += 1;
    return sink.send(&resp);
}

fn bidiEnd(_: *anyopaque, call_id: u32) Status {
    dropState(call_id);
    return Status.ok();
}

var impl = echo.EchoStreamServer{
    .ctx = undefined,
    .clientStreamBegin_fn = clientStreamBegin,
    .clientStreamRequest_fn = clientStreamRequest,
    .clientStreamEnd_fn = clientStreamEnd,
    .bidiBegin_fn = bidiBegin,
    .bidiRequest_fn = bidiRequest,
    .bidiEnd_fn = bidiEnd,
};

export fn run_echo_stream_server() void {
    _ = bridge_mod.Bridge.init(alloc);
    echo.registerEchoStreamServer(&impl);
}
