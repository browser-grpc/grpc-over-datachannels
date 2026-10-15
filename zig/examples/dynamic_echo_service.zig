const std = @import("std");
const grpcdc = @import("grpcdc");

const dynamic = grpcdc.dynamic;
const Status = dynamic.Status;
const GenericMessage = dynamic.GenericMessage;
const MethodModel = dynamic.MethodModel;
const CallContext = grpcdc.endpoint.CallContext;

/// Dynamic Echo implementation: the reference Echo semantics built
/// purely on the descriptor-driven runtime (no generated stubs).
/// Field numbers come from proto/echo.proto: EchoRequest{message=1,
/// count=2}, EchoResponse{message=1, index=2}. Responses are built
/// with the request's allocator (the endpoint allocator) and encoded
/// synchronously by the dynamic adapter.
pub var dynamic_echo_handler = dynamic.DynamicHandler{
    .ctx = undefined,
    .unary_fn = unaryImpl,
    .server_stream_fn = serverStreamImpl,
    .client_stream_fn = clientStreamImpl,
    .bidi_fn = bidiImpl,
};

fn response(alloc: std.mem.Allocator, method: *MethodModel, message: []const u8, index: i64) *GenericMessage {
    const msg = alloc.create(GenericMessage) catch @panic("out of memory");
    msg.* = GenericMessage.init(alloc, method.output);
    const owned = alloc.dupe(u8, message) catch "";
    _ = msg.set(alloc, 1, .{ .string = owned });
    _ = msg.set(alloc, 2, .{ .int = index });
    return msg;
}

fn unaryImpl(_: *anyopaque, ctx: *CallContext, method: *MethodModel, req: *GenericMessage) dynamic.CallResult(*GenericMessage) {
    const alloc = req.alloc;
    const message = req.getString(1);
    if (std.mem.eql(u8, message, "fail")) {
        return .{ .status = Status.init(grpcdc.wire.codeInvalidArgument, "asked to fail") };
    }
    const marker = ctx.metadata.get("x-echo") orelse "";
    const text = if (marker.len > 0)
        std.fmt.allocPrint(alloc, "echo: {s} [{s}]", .{ message, marker }) catch return .{ .status = Status.init(grpcdc.wire.codeResourceExhausted, "out of memory") }
    else
        std.fmt.allocPrint(alloc, "echo: {s}", .{message}) catch return .{ .status = Status.init(grpcdc.wire.codeResourceExhausted, "out of memory") };
    return .{ .ok = response(alloc, method, text, 0) };
}

fn serverStreamImpl(_: *anyopaque, _: *CallContext, method: *MethodModel, req: *GenericMessage, send_fn: dynamic.DynamicSendFn) Status {
    const count = req.getInt(2);
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        const st = send_fn.send(response(req.alloc, method, req.getString(1), i));
        if (!st.isOk()) return st;
    }
    return Status.ok();
}

fn clientStreamImpl(_: *anyopaque, _: *CallContext, method: *MethodModel, recv_fn: dynamic.DynamicRecvFn) dynamic.CallResult(*GenericMessage) {
    var joined: std.ArrayList(u8) = .empty;
    var alloc_opt: ?std.mem.Allocator = null;
    var count: i64 = 0;
    while (true) {
        switch (recv_fn.recv()) {
            .message => |req| {
                if (alloc_opt == null) alloc_opt = req.alloc;
                const alloc = req.alloc;
                if (count > 0) joined.append(alloc, '+') catch return .{ .status = Status.init(grpcdc.wire.codeResourceExhausted, "out of memory") };
                joined.appendSlice(alloc, req.getString(1)) catch return .{ .status = Status.init(grpcdc.wire.codeResourceExhausted, "out of memory") };
                count += 1;
            },
            .end => break,
            .status => |st| return .{ .status = st },
        }
    }
    const alloc = alloc_opt orelse std.heap.page_allocator;
    return .{ .ok = response(alloc, method, joined.items, count) };
}

fn bidiImpl(_: *anyopaque, _: *CallContext, method: *MethodModel, recv_fn: dynamic.DynamicRecvFn, send_fn: dynamic.DynamicSendFn) Status {
    var index: i64 = 0;
    while (true) {
        switch (recv_fn.recv()) {
            .message => |req| {
                const st = send_fn.send(response(req.alloc, method, req.getString(1), index));
                if (!st.isOk()) return st;
                index += 1;
            },
            .end => return Status.ok(),
            .status => |st| return st,
        }
    }
}
