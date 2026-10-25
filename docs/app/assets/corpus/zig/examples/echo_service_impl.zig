const std = @import("std");
const grpcdc = @import("grpcdc");
const wire = grpcdc.wire;
const status_mod = grpcdc.status;
const stubs = @import("echo_grpc_dc.zig");

const Status = status_mod.Status;
const CallContext = stubs.CallContext;
const EchoRequest = stubs.EchoRequest;
const EchoResponse = stubs.EchoResponse;

/// Reference Echo implementation (mirrors the other language demos):
/// "fail" is rejected, everything else echoes. Stateless. Response
/// strings are built with the per-call arena allocator supplied by
/// the generated adapters, so they live until the response is
/// marshaled.
pub var echo_server_impl = stubs.EchoServer{
    .ctx = undefined,
    .unary_fn = unaryImpl,
    .server_stream_fn = serverStreamImpl,
    .client_stream_fn = clientStreamImpl,
    .bidi_fn = bidiImpl,
};

fn unaryImpl(_: *anyopaque, ctx: *CallContext, req: *const EchoRequest, resp: *EchoResponse, alloc: std.mem.Allocator) Status {
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(wire.codeInvalidArgument, "asked to fail");
    }
    if (req.delay_ms > 0) {
        std.Thread.sleep(@as(u64, @intCast(req.delay_ms)) * std.time.ns_per_ms);
    }
    const marker = ctx.metadata.get("x-echo") orelse "";
    if (ctx.metadata.get("x-echo-trailer")) |trailer_marker| {
        if (trailer_marker.len > 0) {
            var tmd = grpcdc.transport.Metadata.init(alloc);
            defer tmd.deinit();
            tmd.put("x-echo-trailer", trailer_marker) catch {};
            ctx.setTrailers(&tmd);
        }
    }
    resp.message = if (marker.len > 0)
        std.fmt.allocPrint(alloc, "echo: {s} [{s}]", .{ req.message, marker }) catch return Status.init(wire.codeResourceExhausted, "out of memory")
    else
        std.fmt.allocPrint(alloc, "echo: {s}", .{req.message}) catch return Status.init(wire.codeResourceExhausted, "out of memory");
    resp.index = 0;
    return Status.ok();
}

fn serverStreamImpl(_: *anyopaque, _: *CallContext, req: *const EchoRequest, stream: *stubs.EchoServerStreamServer) Status {
    if (std.mem.eql(u8, req.message, "fail")) {
        return Status.init(wire.codeInvalidArgument, "asked to fail");
    }
    var i: i32 = 0;
    while (i < req.count) : (i += 1) {
        var resp = EchoResponse{ .message = req.message, .index = i };
        const st = stream.send(&resp);
        if (!st.isOk()) return st;
    }
    return Status.ok();
}

fn clientStreamImpl(_: *anyopaque, _: *CallContext, stream: *stubs.EchoClientStreamServer) Status {
    var joined: std.ArrayList(u8) = .empty;
    var count: i32 = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |req| {
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

fn bidiImpl(_: *anyopaque, _: *CallContext, stream: *stubs.EchoBidiServer) Status {
    var index: i32 = 0;
    while (true) {
        switch (stream.recv()) {
            .message => |req| {
                if (std.mem.eql(u8, req.message, "fail")) {
                    return Status.init(wire.codeInvalidArgument, "asked to fail");
                }
                var resp = EchoResponse{ .message = req.message, .index = index };
                const st = stream.send(&resp);
                if (!st.isOk()) return st;
                index += 1;
            },
            .end => return Status.ok(),
            .status => |st| return st,
        }
    }
}
