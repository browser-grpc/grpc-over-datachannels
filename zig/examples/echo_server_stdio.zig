const std = @import("std");
const grpcdc = @import("grpcdc");
const server_mod = grpcdc.server;
const stdio_mod = @import("stdio_transport.zig");
const stubs = @import("echo_grpc_dc.zig");
const impl = @import("echo_service_impl.zig");

/// Interop harness: the Zig echo server over stdio. Other languages'
/// tests spawn this and drive it with their clients.
pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();
    var transport = stdio_mod.StdioTransport.init(alloc, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    var server = server_mod.Server.init(alloc);
    stubs.EchoGrpcDc.registerEchoServer(&server, &impl.echo_server_impl);
    _ = server.serveTransport(transport.transport());
    // Serve until stdin EOF closes the endpoint or the driver kills us.
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
