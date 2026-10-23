const std = @import("std");

pub fn check(cond: bool, what: []const u8) void {
    if (!cond) {
        std.debug.print("check failed: {s}\n", .{what});
        std.process.exit(1);
    }
}

pub fn checkFmt(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (!cond) {
        std.debug.print("check failed: ", .{});
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        std.process.exit(1);
    }
}

pub fn fromHex(alloc: std.mem.Allocator, hex: []const u8) []u8 {
    const out = alloc.alloc(u8, hex.len / 2) catch @panic("out of memory");
    for (out, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch 0;
    }
    return out;
}

pub fn toHex(alloc: std.mem.Allocator, bytes: []const u8) []u8 {
    return std.fmt.allocPrint(alloc, "{x}", .{bytes}) catch @panic("out of memory");
}

/// Repository root, located by walking up from the cwd looking for
/// fixtures/echo_descriptor_set.bin.
pub fn root(alloc: std.mem.Allocator) []const u8 {
    if (std.posix.getenv("GRPC_DC_ROOT")) |env| {
        if (env.len > 0) return env;
    }
    var dir = std.fs.cwd().realpathAlloc(alloc, ".") catch return ".";
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const direct = std.fmt.allocPrint(alloc, "{s}/fixtures/echo_descriptor_set.bin", .{dir}) catch return ".";
        if (fileExists(direct)) return dir;
        const nested = std.fmt.allocPrint(alloc, "{s}/grpc-over-datachannels", .{dir}) catch return ".";
        const nested_fixture = std.fmt.allocPrint(alloc, "{s}/fixtures/echo_descriptor_set.bin", .{nested}) catch return ".";
        if (fileExists(nested_fixture)) return nested;
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        dir = alloc.dupe(u8, parent) catch return ".";
    }
    return ".";
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn javaClasspath(alloc: std.mem.Allocator, root_path: []const u8) ?[]const u8 {
    const cp_path = std.fmt.allocPrint(alloc, "{s}/oracle/java/target/cp.txt", .{root_path}) catch return null;
    const classes = std.fmt.allocPrint(alloc, "{s}/oracle/java/target/classes", .{root_path}) catch return null;
    const cp = std.fs.cwd().readFileAlloc(alloc, cp_path, 1 << 20) catch return null;
    std.fs.cwd().access(classes, .{}) catch return null;
    const trimmed = std.mem.trim(u8, cp, " \t\r\n");
    return std.fmt.allocPrint(alloc, "{s}:{s}", .{ classes, trimmed }) catch null;
}

pub fn freePort() u16 {
    const addr = std.net.Address.parseIp4("127.0.0.1", 0) catch return 0;
    var listener = addr.listen(.{}) catch return 0;
    const port = listener.listen_address.getPort();
    listener.deinit();
    return port;
}

/// Spawn a child with piped stdin/stdout/stderr.
pub fn spawn(alloc: std.mem.Allocator, argv: []const []const u8) !std.process.Child {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    return child;
}

/// Drain a stream into a growing buffer on a thread (keeps pipes from
/// filling while the test drives the child).
pub const Drain = struct {
    mutex: std.Thread.Mutex = .{},
    buf: std.ArrayList(u8) = .empty,
    done: bool = false,

    pub fn run(self: *Drain, alloc: std.mem.Allocator, file: std.fs.File) void {
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = file.read(&chunk) catch break;
            if (n == 0) break;
            self.mutex.lock();
            self.buf.appendSlice(alloc, chunk[0..n]) catch {};
            self.mutex.unlock();
        }
        self.mutex.lock();
        self.done = true;
        self.mutex.unlock();
    }

    pub fn text(self: *Drain) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buf.items;
    }

    pub fn contains(self: *Drain, needle: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return std.mem.indexOf(u8, self.buf.items, needle) != null;
    }

    pub fn isDone(self: *Drain) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }
};

pub fn startDrain(alloc: std.mem.Allocator, drain: *Drain, file: std.fs.File) void {
    const thread = std.Thread.spawn(.{}, Drain.run, .{ drain, alloc, file }) catch return;
    thread.detach();
}

/// Wait until the drain buffer contains needle (timeout in ms).
pub fn waitReady(drain: *Drain, needle: []const u8, timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < timeout_ms) {
        if (drain.contains(needle)) return true;
        if (drain.isDone()) return drain.contains(needle);
        std.Thread.sleep(10 * std.time.ns_per_ms);
        waited += 10;
    }
    return drain.contains(needle);
}

/// Wait for child exit with a timeout; kills on expiry. Returns the
/// exit code, or -1 on timeout/signal.
pub fn waitExit(child: *std.process.Child, timeout_ms: u64) i32 {
    const WaitCtx = struct {
        child: *std.process.Child,
        code: ?i32 = null,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        fn run(self: *@This()) void {
            const term = self.child.wait() catch {
                self.finish(-1);
                return;
            };
            self.finish(switch (term) {
                .Exited => |code| @as(i32, @intCast(code)),
                else => -1,
            });
        }

        fn finish(self: *@This(), code: i32) void {
            self.mutex.lock();
            self.code = code;
            self.mutex.unlock();
            self.cond.broadcast();
        }
    };
    const ctx = @import("std").heap.page_allocator.create(WaitCtx) catch return -1;
    ctx.* = .{ .child = child };
    const thread = std.Thread.spawn(.{}, WaitCtx.run, .{ctx}) catch return -1;
    thread.detach();
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    var waited: u64 = 0;
    while (ctx.code == null and waited < timeout_ms) {
        // Timed wait via short sleep loop (Condition has no timeout).
        ctx.mutex.unlock();
        std.Thread.sleep(10 * std.time.ns_per_ms);
        waited += 10;
        ctx.mutex.lock();
    }
    if (ctx.code) |code| return code;
    _ = child.kill() catch {};
    return -1;
}

pub fn killChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}
