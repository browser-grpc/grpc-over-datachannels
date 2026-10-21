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
    // BDD deepening fields, filled by the deep chain below.
    unary_failure_code: i32 = -99,
    metadata: []u8 = "",
    server_stream_failure_code: i32 = -99,
    bidi_failure_code: i32 = -99,
    unknown_method_code: i32 = -99,
    cancel_seen: i32 = 0,
    deadline_code: i32 = -99,
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
    // BDD deepening chain: failure, metadata, unknown-method,
    // cancel, and deadline scenarios run inside this module.
    client.unary(&req("fail", 0), state_ptr, onFailUnary);
}

// Raw bridge pending for metadata/unknown/deadline calls.
const RawCall = struct {
    st: *State,
    step: u8,

    fn allocCall(st: *State, step: u8) *RawCall {
        const self = alloc.create(RawCall) catch unreachable;
        self.* = .{ .st = st, .step = step };
        return self;
    }

    fn complete(raw: *anyopaque, status: echo.Status, payload: ?[]const u8) void {
        const self: *RawCall = @ptrCast(@alignCast(raw));
        const st = self.st;
        const step = self.step;
        alloc.destroy(self);
        switch (step) {
            0 => { // metadata unary
                if (status.isOk()) {
                    var resp = echo.EchoResponse{};
                    resp.unmarshalDc(alloc, payload orelse "");
                    st.metadata = alloc.dupe(u8, resp.message) catch "";
                }
                client.serverStream(&req("fail", 3), st, onDeepMsg, onStreamFailDone);
            },
            1 => { // unknown method
                st.unknown_method_code = status.code;
                const p = req("tick", 5).marshalDc(alloc);
                defer alloc.free(p);
                bridge.serverStreamCancelAfter("/echo.Echo/ServerStream", p, 1, st, onCancelMsg, onCancelDone);
            },
            2 => { // deadline unary
                st.deadline_code = status.code;
                emitResult(st);
            },
            else => {},
        }
    }
};

fn onFailUnary(ctx: *anyopaque, result: echo.CallResult(echo.EchoResponse)) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    st.unary_failure_code = switch (result) {
        .status => |s| s.code,
        .ok => 0,
    };
    const p = req("hello", 0).marshalDc(alloc);
    defer alloc.free(p);
    bridge.unaryWithOptions("/echo.Echo/Unary", p,
        "{\"metadata\":{\"x-echo\":\"meta\"}}",
        RawCall.allocCall(st, 0), RawCall.complete);
}

fn onDeepMsg(_: *anyopaque, _: echo.EchoResponse) void {}

fn onStreamFailDone(ctx: *anyopaque, st: echo.Status) void {
    const state_ptr: *State = @ptrCast(@alignCast(ctx));
    state_ptr.server_stream_failure_code = st.code;
    client.bidi(&.{req("fail", 0)}, state_ptr, onDeepMsg, onBidiFailDone);
}

fn onBidiFailDone(ctx: *anyopaque, st: echo.Status) void {
    const state_ptr: *State = @ptrCast(@alignCast(ctx));
    state_ptr.bidi_failure_code = st.code;
    const p = req("hello", 0).marshalDc(alloc);
    defer alloc.free(p);
    bridge.unary("/echo.Echo/Nope", p, RawCall.allocCall(state_ptr, 1), RawCall.complete);
}

fn onCancelMsg(ctx: *anyopaque, _: []const u8) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    st.cancel_seen += 1;
}

fn onCancelDone(ctx: *anyopaque, _: echo.Status, _: ?[]const u8) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    var slow = req("slow", 0);
    slow.delay_ms = 600;
    const p = slow.marshalDc(alloc);
    defer alloc.free(p);
    bridge.unaryWithOptions("/echo.Echo/Unary", p,
        "{\"timeout\":100}", RawCall.allocCall(st, 2), RawCall.complete);
}

fn emitResult(state_ptr: *State) void {
    const Result = struct {
        unary: []const u8,
        ticks: []const i32,
        joined: []const u8,
        echoed: []const []const u8,
        @"unaryFailureCode": i32,
        @"metadataMessage": []const u8,
        @"serverStreamFailureCode": i32,
        @"bidiFailureCode": i32,
        @"unknownMethodCode": i32,
        @"cancelTerminated": bool,
        @"deadlineCode": i32,
    };
    const echoed: []const []const u8 = @ptrCast(state_ptr.echoed.items);
    const json = std.json.Stringify.valueAlloc(alloc, Result{
        .unary = state_ptr.unary,
        .ticks = state_ptr.ticks.items,
        .joined = state_ptr.joined,
        .echoed = echoed,
        .@"unaryFailureCode" = state_ptr.unary_failure_code,
        .@"metadataMessage" = state_ptr.metadata,
        .@"serverStreamFailureCode" = state_ptr.server_stream_failure_code,
        .@"bidiFailureCode" = state_ptr.bidi_failure_code,
        .@"unknownMethodCode" = state_ptr.unknown_method_code,
        .@"cancelTerminated" = state_ptr.cancel_seen == 1,
        .@"deadlineCode" = state_ptr.deadline_code,
    }, .{}) catch {
        on_error("out of memory".ptr, "out of memory".len);
        return;
    };
    on_result(json.ptr, json.len);
}
