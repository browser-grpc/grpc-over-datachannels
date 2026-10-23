const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");

/// Interop harness: the dynamic (descriptor-driven) Zig echo server
/// over stdio. Loads fixtures/echo_descriptor_set.bin at runtime —
/// no generated stubs involved. Used by the oracle tests.
pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();
    const fixture = locateFixtures(alloc) orelse {
        std.debug.print("fixtures/echo_descriptor_set.bin not found\n", .{});
        std.process.exit(1);
    };
    const data = std.fs.cwd().readFileAlloc(alloc, fixture, 1 << 24) catch {
        std.debug.print("cannot read {s}\n", .{fixture});
        std.process.exit(1);
    };
    const model = grpcdc.dynamic.parseDescriptorSet(alloc, data);
    var transport = examples.stdio_transport.StdioTransport.init(alloc, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    var server = grpcdc.server.Server.init(alloc);
    grpcdc.dynamic.registerDynamicService(&server, model, "echo.Echo", &examples.dynamic_echo_service.dynamic_echo_handler);
    _ = server.serveTransport(transport.transport());
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

fn locateFixtures(alloc: std.mem.Allocator) ?[]const u8 {
    var dir = std.fs.cwd().realpathAlloc(alloc, ".") catch return null;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const direct = std.fmt.allocPrint(alloc, "{s}/fixtures/echo_descriptor_set.bin", .{dir}) catch return null;
        if (exists(direct)) return direct;
        const nested = std.fmt.allocPrint(alloc, "{s}/grpc-over-datachannels/fixtures/echo_descriptor_set.bin", .{dir}) catch return null;
        if (exists(nested)) return nested;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = @constCast(parent);
    }
    return null;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
