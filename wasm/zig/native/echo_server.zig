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
extern "env" fn on_result(ptr: [*]const u8, len: usize) void;

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

// Matrix tracing entry: same server with a recording span
// observer; every span start/end re-reports the cumulative
// spans through on_result so the page can expose them to the
// matrix driver (window.__spans) while the pump keeps running.
const TraceStart = struct {
    kind: [16]u8,
    kind_len: usize,
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: [16]u8,
    parent_len: usize,
};

const TraceRecorder = struct {
    starts: [8]TraceStart = undefined,
    start_count: usize = 0,
    end_kinds: [8][16]u8 = undefined,
    end_lens: [8]usize = undefined,
    end_count: usize = 0,

    fn report(self: *TraceRecorder) void {
        var starts_json: std.ArrayList(u8) = .empty;
        for (self.starts[0..self.start_count], 0..) |s, i| {
            if (i > 0) starts_json.appendSlice(alloc, ",") catch return;
            starts_json.appendSlice(alloc, std.fmt.allocPrint(alloc, "[\"{s}\",\"{s}\",\"{s}\",\"{s}\"]", .{
                s.kind[0..s.kind_len], &s.trace_id, &s.span_id, s.parent_span_id[0..s.parent_len],
            }) catch return) catch return;
        }
        var ends_json: std.ArrayList(u8) = .empty;
        for (self.end_kinds[0..self.end_count], self.end_lens[0..self.end_count], 0..) |k, len, i| {
            if (i > 0) ends_json.appendSlice(alloc, ",") catch return;
            ends_json.appendSlice(alloc, std.fmt.allocPrint(alloc, "\"{s}\"", .{k[0..len]}) catch return) catch return;
        }
        const json = std.fmt.allocPrint(alloc, "{{\"starts\":[{s}],\"ends\":[{s}]}}", .{
            starts_json.items, ends_json.items,
        }) catch return;
        on_result(json.ptr, json.len);
    }

    fn onStart(ctx: *anyopaque, kind: []const u8, _method: []const u8, trace_id: []const u8, span_id: []const u8, parent_span_id: []const u8) void {
        _ = _method;
        const self: *TraceRecorder = @ptrCast(@alignCast(ctx));
        var s = TraceStart{
            .kind = [_]u8{0} ** 16,
            .kind_len = kind.len,
            .trace_id = [_]u8{0} ** 32,
            .span_id = [_]u8{0} ** 16,
            .parent_span_id = [_]u8{0} ** 16,
            .parent_len = parent_span_id.len,
        };
        @memcpy(s.kind[0..kind.len], kind);
        @memcpy(&s.trace_id, trace_id[0..32]);
        @memcpy(&s.span_id, span_id[0..16]);
        if (parent_span_id.len != 0) @memcpy(&s.parent_span_id, parent_span_id[0..16]);
        self.starts[self.start_count] = s;
        self.start_count += 1;
        self.report();
    }

    fn onEnd(ctx: *anyopaque, kind: []const u8, _method: []const u8, _trace_id: []const u8, _span_id: []const u8, _status: []const u8, _duration_ms: f64) void {
        _ = _method;
        _ = _trace_id;
        _ = _span_id;
        _ = _status;
        _ = _duration_ms;
        const self: *TraceRecorder = @ptrCast(@alignCast(ctx));
        self.end_kinds[self.end_count] = [_]u8{0} ** 16;
        @memcpy(self.end_kinds[self.end_count][0..kind.len], kind);
        self.end_lens[self.end_count] = kind.len;
        self.end_count += 1;
        self.report();
    }
};

var trace_recorder = TraceRecorder{};

export fn run_echo_server_tracing() void {
    grpcdc.status.setTracer(.{ .ctx = &trace_recorder, .on_start = TraceRecorder.onStart, .on_end = TraceRecorder.onEnd });
    var dc = dc_transport.DcTransport{};
    var server = grpcdc.server.Server.init(alloc);
    stubs.EchoGrpcDc.registerEchoServer(&server, &echo_impl);
    const endpoint = server.serveTransport(dc.transport());
    while (true) {
        endpoint.pollOnce();
    }
}
