const std = @import("std");

/// Builds the test runner and the stdio interop harnesses.
/// Everything is stdlib-only; no package dependencies.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const grpcdc = b.addModule("grpcdc", .{
        .root_source_file = b.path("grpcdc/grpcdc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const examples = b.addModule("examples", .{
        .root_source_file = b.path("examples/examples.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "grpcdc", .module = grpcdc }},
    });

    const names = [_][2][]const u8{
        .{ "tests", "tests/main.zig" },
        .{ "echo_server_stdio", "examples/echo_server_stdio.zig" },
        .{ "echo_client_stdio", "examples/echo_client_stdio.zig" },
        .{ "dynamic_echo_server_stdio", "examples/dynamic_echo_server_stdio.zig" },
        .{ "interop_server_stdio", "examples/interop_server_stdio.zig" },
        .{ "eventbus_demo", "examples/eventbus_demo.zig" },
    };
    for (names) |entry| {
        const exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "grpcdc", .module = grpcdc },
                    .{ .name = "examples", .module = examples },
                },
            }),
        });
        b.installArtifact(exe);
    }
}
