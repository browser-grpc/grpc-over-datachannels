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

// Matrix tracing entry: one traced unary over the real
// DataChannel transport; spans ride back in the result JSON in
// the same shape the nested tracing entry reports.
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
    end_count: usize = 0,

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
    }

    fn onEnd(ctx: *anyopaque, _kind: []const u8, _method: []const u8, _trace_id: []const u8, _span_id: []const u8, _status: []const u8, _duration_ms: f64) void {
        _ = _kind;
        _ = _method;
        _ = _trace_id;
        _ = _span_id;
        _ = _status;
        _ = _duration_ms;
        const self: *TraceRecorder = @ptrCast(@alignCast(ctx));
        self.end_count += 1;
    }
};

export fn run_echo_client_tracing() void {
    var recorder = TraceRecorder{};
    grpcdc.status.setTracer(.{ .ctx = &recorder, .on_start = TraceRecorder.onStart, .on_end = TraceRecorder.onEnd });
    defer grpcdc.status.setTracer(null);

    var dc = dc_transport.DcTransport{};
    var channel = grpcdc.channel.Channel.init(alloc, dc.transport());
    defer channel.deinit();
    var client = stubs.EchoClient.init(&channel);
    const resp = switch (client.unary(&req("hello", 0), null, null)) {
        .ok => |r| r,
        .status => |st| return fail(st),
    };
    var starts_json: std.ArrayList(u8) = .empty;
    for (recorder.starts[0..recorder.start_count], 0..) |s, i| {
        if (i > 0) starts_json.appendSlice(alloc, ",") catch return fail(stubs.Status.init(13, "out of memory"));
        starts_json.appendSlice(alloc, std.fmt.allocPrint(alloc, "[\"{s}\",\"{s}\",\"{s}\",\"{s}\"]", .{
            s.kind[0..s.kind_len], &s.trace_id, &s.span_id, s.parent_span_id[0..s.parent_len],
        }) catch return fail(stubs.Status.init(13, "out of memory"))) catch return fail(stubs.Status.init(13, "out of memory"));
    }
    const json = std.fmt.allocPrint(alloc, "{{\"message\":\"{s}\",\"starts\":[{s}],\"ends\":{d}}}", .{
        resp.message, starts_json.items, recorder.end_count,
    }) catch return fail(stubs.Status.init(13, "out of memory"));
    on_result(json.ptr, json.len);
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

    // BDD deepening: failure, metadata, unknown-method, and
    // cancellation scenarios executed by this module.
    const unary_failure_code: i32 = switch (client.unary(&req("fail", 0), null, null)) {
        .ok => 0,
        .status => |st| st.code,
    };
    var md_map = grpcdc.transport.Metadata.init(alloc);
    defer md_map.deinit();
    md_map.put("x-echo", "meta") catch {};
    const metadata_resp = switch (client.unary(&req("hello", 0), &md_map, null)) {
        .ok => |r| r,
        .status => |st| return fail(st),
    };
    const metadata_msg = alloc.dupe(u8, metadata_resp.message) catch return fail(stubs.Status.init(13, "out of memory"));
    const server_stream_failure_code: i32 = blk: {
        var s = switch (client.serverStream(&req("fail", 3), null, null)) {
            .ok => |s| s,
            .status => |st| break :blk st.code,
        };
        defer s.deinit();
        while (true) {
            switch (s.recv()) {
                .message => {},
                .end => break :blk 0,
                .status => |st| break :blk st.code,
            }
        }
    };
    const bidi_failure_code: i32 = blk: {
        var s = switch (client.bidi(&.{req("fail", 0)}, null, null)) {
            .ok => |s| s,
            .status => |st| break :blk st.code,
        };
        defer s.deinit();
        while (true) {
            switch (s.recv()) {
                .message => {},
                .end => break :blk 0,
                .status => |st| break :blk st.code,
            }
        }
    };
    const unknown_method_code: i32 = blk: {
        var request = req("hello", 0);
        var resp = stubs.EchoResponse{};
        break :blk channel.unary("/echo.Echo/Nope", &request, &resp, null, null).code;
    };
    const cancel_terminated: bool = blk: {
        var s = switch (client.serverStream(&req("tick", 5), null, null)) {
            .ok => |s| s,
            .status => break :blk false,
        };
        defer s.deinit();
        switch (s.recv()) {
            .message => {},
            else => break :blk false,
        }
        s.stream.cancel();
        var terminated = false;
        var i: i32 = 0;
        while (i < 7 and !terminated) : (i += 1) {
            switch (s.recv()) {
                .message => {},
                .end => terminated = true,
                .status => terminated = true,
            }
        }
        break :blk terminated;
    };

    var slow = req("slow", 0);
    slow.delay_ms = 400;
    const deadline_code: i32 = switch (client.unary(&slow, null, 50)) {
        .ok => 0,
        .status => |st| st.code,
    };

    const Result = struct {
        unary: []const u8,
        ticks: []const i32,
        joined: []const u8,
        echoed: []const []const u8,
        deadlineCode: i32,
        unaryFailureCode: i32,
        metadataMessage: []const u8,
        serverStreamFailureCode: i32,
        bidiFailureCode: i32,
        unknownMethodCode: i32,
        cancelTerminated: bool,
    };
    const echoed_view: []const []const u8 = @ptrCast(echoed.items);
    const json = std.json.Stringify.valueAlloc(alloc, Result{
        .unary = unary_msg,
        .ticks = ticks.items,
        .joined = joined_msg,
        .echoed = echoed_view,
        .deadlineCode = deadline_code,
        .unaryFailureCode = unary_failure_code,
        .metadataMessage = metadata_msg,
        .serverStreamFailureCode = server_stream_failure_code,
        .bidiFailureCode = bidi_failure_code,
        .unknownMethodCode = unknown_method_code,
        .cancelTerminated = cancel_terminated,
    }, .{}) catch return fail(stubs.Status.init(13, "out of memory"));
    on_result(json.ptr, json.len);
}
