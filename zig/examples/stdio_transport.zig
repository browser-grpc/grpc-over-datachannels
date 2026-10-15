const std = @import("std");
const grpcdc = @import("grpcdc");
const transport_mod = grpcdc.transport;

/// Frames DataChannel messages over a byte stream with a 4-byte
/// big-endian length prefix (the prefix exists only to frame messages
/// on a byte stream; each framed unit is exactly one DataChannel
/// message). Used by the cross-language interop harnesses over
/// stdin/stdout or process pipes.
pub const StdioTransport = struct {
    alloc: std.mem.Allocator,
    in_fd: std.posix.fd_t,
    out_fd: std.posix.fd_t,
    pending: std.ArrayList(u8) = .empty,
    send_mutex: std.Thread.Mutex = .{},
    closed: bool = false,
    eof: bool = false,

    pub fn init(alloc: std.mem.Allocator, in_fd: std.posix.fd_t, out_fd: std.posix.fd_t) StdioTransport {
        return .{ .alloc = alloc, .in_fd = in_fd, .out_fd = out_fd };
    }

    pub fn transport(self: *StdioTransport) transport_mod.Transport {
        return .{ .ctx = self, .send_fn = sendFn, .recv_fn = recvFn, .close_fn = closeFn };
    }

    fn sendFn(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (self.closed) return error.Closed;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(data.len), .big);
        try writeAll(self.out_fd, &header);
        try writeAll(self.out_fd, data);
    }

    fn recvFn(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!?[]u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        while (true) {
            if (self.pending.items.len >= 4) {
                const len = std.mem.readInt(u32, self.pending.items[0..4], .big);
                if (self.pending.items.len >= 4 + len) {
                    const msg = try alloc.dupe(u8, self.pending.items[4 .. 4 + len]);
                    const rest = self.pending.items[4 + len ..];
                    const rest_copy = try self.alloc.dupe(u8, rest);
                    self.pending.clearRetainingCapacity();
                    try self.pending.appendSlice(self.alloc, rest_copy);
                    self.alloc.free(rest_copy);
                    return msg;
                }
            }
            if (self.eof or self.closed) return null;
            // Poll with a timeout: closing a descriptor does not wake
            // a blocked reader on Linux, so the closed flag is checked
            // between polls instead.
            var fds = [_]std.posix.pollfd{.{ .fd = self.in_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 100) catch return null;
            if (self.closed) return null;
            if (ready == 0) continue;
            var buf: [16384]u8 = undefined;
            const n = std.posix.read(self.in_fd, &buf) catch return null;
            if (n == 0) {
                self.eof = true;
                return null;
            }
            try self.pending.appendSlice(self.alloc, buf[0..n]);
        }
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *StdioTransport = @ptrCast(@alignCast(ctx));
        self.closed = true; // recvFn polls this flag between reads
    }
};

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        written += try std.posix.write(fd, data[written..]);
    }
}
