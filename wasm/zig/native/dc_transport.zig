//! Native DataChannel transport for the browser/WASM build:
//! the real generated grpcdc runtime over the page's
//! RTCDataChannel. Runs in a Web Worker; js_dc_recv waits on
//! a SharedArrayBuffer mailbox the page fills (see
//! browser-test/wasm_zig_native_worker.js). Provides
//! try_recv_fn, so the grpcdc endpoint runs in its inline
//! pump mode (no threads under wasm32-freestanding).

const std = @import("std");
const grpcdc = @import("grpcdc");

extern "env" fn js_dc_send(ptr: [*]const u8, len: usize) void;
/// Returns message length, -1 on timeout, -2 when closed.
extern "env" fn js_dc_recv(ptr: [*]u8, cap: usize, timeout_ms: i32) i32;
extern "env" fn js_now_ms() f64;

fn hostNowMs() i64 {
    return @intFromFloat(js_now_ms());
}

const MAX_MESSAGE = 256 * 1024;
var recv_buf: [MAX_MESSAGE]u8 = undefined;

pub const DcTransport = struct {
    pub fn transport(self: *DcTransport) grpcdc.endpoint.Transport {
        grpcdc.endpoint.setNowMsHook(&hostNowMs);
        return .{
            .ctx = self,
            .send_fn = &sendFn,
            .recv_fn = &recvFn,
            .close_fn = &closeFn,
            .try_recv_fn = &tryRecvFn,
        };
    }

    fn sendFn(_: *anyopaque, data: []const u8) anyerror!void {
        js_dc_send(data.ptr, data.len);
    }

    fn recvOnce(alloc: std.mem.Allocator, timeout_ms: i32) anyerror!?[]u8 {
        const n = js_dc_recv(&recv_buf, MAX_MESSAGE, timeout_ms);
        if (n == -1) return error.WouldBlock;
        if (n == -2) return null;
        if (n < 0) return error.TransportClosed;
        return try alloc.dupe(u8, recv_buf[0..@intCast(n)]);
    }

    fn recvFn(_: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 {
        while (true) {
            if (recvOnce(alloc, 50)) |msg| {
                return msg;
            } else |err| {
                if (err != error.WouldBlock) return err;
            }
        }
    }

    fn tryRecvFn(_: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 {
        return recvOnce(alloc, 50);
    }

    fn closeFn(_: *anyopaque) void {}
};
