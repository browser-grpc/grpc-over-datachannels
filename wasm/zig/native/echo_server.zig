//! Browser test entry point (native runtime, server role):
//! runs the generated Zig Echo server (zig/examples
//! echo_grpc_dc.zig) over the real grpcdc runtime on a
//! DataChannel transport, in a Web Worker. The endpoint runs
//! in inline pump mode (try_recv transport), so this loop
//! drives dispatch; handler stream waits re-enter pollOnce.
//! The JS client in the Node test drives the four call
//! shapes plus a deadline the slow handler must miss.
//! Mirrors wasm/kotlin/native/echo_server.kt (own impl:
//! Zig modules cannot share the stdio impl's stub file).

const std = @import("std");
const grpcdc = @import("grpcdc");
const stubs = @import("echo_stub");
const dc_transport = @import("./dc_transport.zig");

extern "env" fn js_now_ms() f64;

const alloc = std.heap.wasm_allocator;
const Status = stubs.Status;
const wire = grpcdc.wire;

fn delayMs(ms: i32) void {
    if (ms <= 0) return;
    // No sleep under wasm32-freestanding: busy-wait on the
    // host monotonic clock.
    const until = js_now_ms() + @as(f64, @floatFromInt(ms));
    while (js_now_ms() < until) {}
}

fn unaryImpl(_: *anyopaque, ctx: *stubs.CallContext, req: *const stubs.EchoRequest, resp: *stubs.EchoResponse, a: std.mem.Allocator) Status {
    delayMs(req.delay_ms);
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(wire.codeInvalidArgument, "asked to fail");
    }
    const marker = ctx.metadata.get("x-echo") orelse "";
    resp.message = if (marker.len > 0)
        std.fmt.allocPrint(a, "echo: {s} [{s}]", .{ req.message, marker }) catch return Status.init(wire.codeResourceExhausted, "out of memory")
    else
        std.fmt.allocPrint(a, "echo: {s}", .{req.message}) catch return Status.init(wire.codeResourceExhausted, "out of memory");
    resp.index = 0;
    return Status.ok();
}

fn serverStreamImpl(_: *anyopaque, _: *stubs.CallContext, req: *const stubs.EchoRequest, stream: *stubs.EchoServerStreamServer) Status {
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(wire.codeInvalidArgument, "asked to fail");
    }
    var i: i32 = 0;
    while (i < req.count) : (i += 1) {
        var resp = stubs.EchoResponse{ .message = req.message, .index = i };
        const st = stream.send(&resp);
        if (!st.isOk()) return st;
    }
    return Status.ok();
}

fn clientStreamImpl(_: *anyopaque, _: *stubs.CallContext, stream: *stubs.EchoClientStreamServer) Status {
    var joined: std.ArrayList(u8) = .empty;
    var count: i32 = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |req| {
                if (std.mem.eql(u8, req.message, "fail")) {
                    return Status.init(wire.codeInvalidArgument, "asked to fail");
                }
                if (count > 0) joined.append(stream.alloc, '+') catch return Status.init(wire.codeResourceExhausted, "out of memory");
                joined.appendSlice(stream.alloc, req.message) catch return Status.init(wire.codeResourceExhausted, "out of memory");
                count += 1;
            },
            .end => break,
            .status => |st| return st,
        }
    }
    stream.sendAndClose(.{ .message = joined.items, .index = count });
    return Status.ok();
}

fn bidiImpl(_: *anyopaque, _: *stubs.CallContext, stream: *stubs.EchoBidiServer) Status {
    var index: i32 = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |req| {
                if (std.mem.eql(u8, req.message, "fail")) {
                    return Status.init(wire.codeInvalidArgument, "asked to fail");
                }
                var resp = stubs.EchoResponse{ .message = req.message, .index = index };
                const st = stream.send(&resp);
                if (!st.isOk()) return st;
                index += 1;
            },
            .end => return Status.ok(),
            .status => |st| return st,
        }
    }
}

var echo_impl = stubs.EchoServer{
    .ctx = undefined,
    .unary_fn = unaryImpl,
    .server_stream_fn = serverStreamImpl,
    .client_stream_fn = clientStreamImpl,
    .bidi_fn = bidiImpl,
};

export fn run_echo_server() void {
    var dc = dc_transport.DcTransport{};
    var server = grpcdc.server.Server.init(alloc);
    stubs.EchoGrpcDc.registerEchoServer(&server, &echo_impl);
    const endpoint = server.serveTransport(dc.transport());
    // PollOnce returns promptly when closed; the worker lives
    // for the page's lifetime, so pump forever.
    while (true) {
        endpoint.pollOnce();
    }
}
