const std = @import("std");
const grpcdc = @import("grpcdc");
const server_mod = grpcdc.server;
const stdio_mod = @import("stdio_transport.zig");
const test_stubs = @import("interop/test_grpc_dc.zig");
const orca_stubs = @import("interop/orca_grpc_dc.zig");
const impl = @import("interop_service_impl.zig");

/// Interop harness: the Zig TestService server over stdio.
/// Direction-B oracle tests spawn this and drive it with the
/// official grpc-java / grpc-go interop clients through the
/// bridge (oracle/bridge.mjs http2-to-dc).
pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();
    var transport = stdio_mod.StdioTransport.init(alloc, std.posix.STDIN_FILENO, std.posix.STDOUT_FILENO);
    var server = server_mod.Server.init(alloc);
    test_stubs.TestGrpcDc.registerTestServiceServer(&server, &impl.test_service_impl);
    orca_stubs.OrcaGrpcDc.registerOpenRcaServiceServer(&server, &impl.open_rca_impl);
    _ = server.serveTransport(transport.transport());
    // Serve until stdin EOF closes the endpoint or the driver kills us.
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}
