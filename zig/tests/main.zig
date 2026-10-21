const std = @import("std");
const test_bdd = @import("test_bdd.zig");
const test_deadline = @import("test_deadline.zig");
const test_codec = @import("test_codec.zig");
const test_echo = @import("test_echo.zig");
const test_interop = @import("test_interop.zig");
const test_oracle = @import("test_oracle.zig");
const test_dynamic = @import("test_dynamic.zig");
const test_pb_messages = @import("test_pb_messages.zig");
const test_bdd_schemas = @import("test_bdd_schemas.zig");
const test_sidecar = @import("test_sidecar.zig");

// Test runner: ./tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic>
pub fn main() !void {
    var dba: std.heap.DebugAllocator(.{}) = .init;
    const alloc = dba.allocator();
    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        std.debug.print("usage: tests <TestCodec|TestEcho|TestInterop|TestOracle|TestDynamic|TestBdd|TestDeadline>\n", .{});
        std.process.exit(2);
    }
    const name = args[1];
    if (std.mem.eql(u8, name, "TestBdd")) {
        test_bdd.testBdd(alloc);
    } else if (std.mem.eql(u8, name, "TestCodec")) {
        test_codec.testCodec(alloc);
    } else if (std.mem.eql(u8, name, "TestEcho")) {
        test_echo.testEcho(alloc);
    } else if (std.mem.eql(u8, name, "TestInterop")) {
        test_interop.testInterop(alloc);
    } else if (std.mem.eql(u8, name, "TestOracle")) {
        test_oracle.testOracle(alloc);
    } else if (std.mem.eql(u8, name, "TestDynamic")) {
        test_dynamic.testDynamic(alloc);
    } else if (std.mem.eql(u8, name, "TestDeadline")) {
        test_deadline.testDeadline(alloc);
    } else if (std.mem.eql(u8, name, "TestBddSchemas")) {
        test_bdd_schemas.testBddSchemas(alloc);
    } else if (std.mem.eql(u8, name, "TestPbMessages")) {
        test_pb_messages.testPbMessages(alloc);
    } else if (std.mem.eql(u8, name, "TestSidecar")) {
        test_sidecar.testSidecar(alloc);
    } else {
        std.debug.print("unknown test: {s}\n", .{name});
        std.process.exit(2);
    }
}
