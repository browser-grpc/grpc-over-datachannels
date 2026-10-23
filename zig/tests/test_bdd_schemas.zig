const std = @import("std");
const util = @import("test_util.zig");
const schemas = @import("bdd_schemas.zig");

/// BDD schema scenarios: golden protoc bytes, generated classes.
/// The case table (bdd_schemas.zig) is stamped from
/// racket/bdd-schemas.rkt: protoc's own --encode output over
/// webapp/testdata/{kitchen,features}.proto. Each case decodes
/// with the generated classes and re-encodes byte-identically.
/// The generated-classes harness mirrors test_pb_messages.zig.
pub fn testBddSchemas(alloc: std.mem.Allocator) void {
    const harness_head =
        \\const std = @import("std");
        \\const kitchen = @import("kitchen_messages.zig");
        \\const features = @import("features_messages.zig");
        \\
        \\fn fail(msg: []const u8) noreturn {
        \\    std.debug.print("FAIL: {s}\n", .{msg});
        \\    std.process.exit(1);
        \\}
        \\
        \\fn unhex(alloc: std.mem.Allocator, s: []const u8) []u8 {
        \\    const out = alloc.alloc(u8, s.len / 2) catch unreachable;
        \\    for (out, 0..) |*b, i| {
        \\        b.* = std.fmt.parseInt(u8, s[i * 2 .. i * 2 + 2], 16) catch unreachable;
        \\    }
        \\    return out;
        \\}
        \\
        \\fn hex(alloc: std.mem.Allocator, bytes: []const u8) []u8 {
        \\    return std.fmt.allocPrint(alloc, "{x}", .{bytes}) catch unreachable;
        \\}
        \\
        \\const Case = struct { name: []const u8, message: []const u8, input: []const u8, expect: []const u8 };
        \\
        \\pub fn main() void {
        \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        \\    const alloc = arena.allocator();
        \\    const cases = [_]Case{
        \\
    ;
    const harness_tail =
        \\    };
        \\    for (cases) |c| {
        \\        const input = unhex(alloc, c.input);
        \\        var got: []u8 = undefined;
        \\        if (std.mem.eql(u8, c.message, "kitchen")) {
        \\            var m = kitchen.Kitchen{};
        \\            m.unmarshalDc(alloc, input);
        \\            got = m.marshalDc(alloc);
        \\        } else if (std.mem.eql(u8, c.message, "outer")) {
        \\            var m = features.Outer{};
        \\            m.unmarshalDc(alloc, input);
        \\            got = m.marshalDc(alloc);
        \\        } else {
        \\            fail("unknown message");
        \\        }
        \\        if (!std.mem.eql(u8, hex(alloc, got), c.expect)) fail(c.name);
        \\    }
        \\    std.debug.print("schemas OK\n", .{});
        \\}
        \\
    ;

    var harness: std.ArrayList(u8) = .empty;
    harness.appendSlice(alloc, harness_head) catch unreachable;
    for (schemas.cases) |c| {
        harness.appendSlice(alloc, allocPrint(alloc,
            "        .{{ .name = \"{s}\", .message = \"{s}\", .input = \"{s}\", .expect = \"{s}\" }},\n",
            .{ c.name, c.message, c.input, c.expect })) catch unreachable;
    }
    harness.appendSlice(alloc, harness_tail) catch unreachable;

    const root = util.root(alloc);
    const testdata = join(alloc, root, "webapp/testdata");
    const tmp: []const u8 = "/tmp/grpcdc-zig-schemas";
    run(alloc, &.{ "rm", "-rf", tmp });
    const gen = join(alloc, tmp, "gen");
    run(alloc, &.{ "mkdir", "-p", gen });
    run(alloc, &.{
        "protoc",
        allocPrint(alloc, "--plugin=protoc-gen-grpc-dc-zig={s}/bin/protoc-gen-grpc-dc-zig", .{root}),
        allocPrint(alloc, "--grpc-dc-zig_out={s}", .{gen}),
        "-I", testdata, "common.proto", "kitchen.proto", "features.proto",
    });
    std.fs.cwd().deleteFile(join(alloc, gen, "common_grpc_dc.zig")) catch {};
    std.fs.cwd().deleteFile(join(alloc, gen, "kitchen_grpc_dc.zig")) catch {};
    std.fs.cwd().deleteFile(join(alloc, gen, "features_grpc_dc.zig")) catch {};
    writeFile(join(alloc, gen, "main.zig"), harness.items);
    run(alloc, &.{ "zig", "build-exe",
        join(alloc, gen, "main.zig"),
        allocPrint(alloc, "-femit-bin={s}/harness", .{tmp}) });
    // The harness prints "schemas OK" via debug (stderr) and
    // exits non-zero on any mismatch; capture asserts exit 0.
    _ = capture(alloc, &.{join(alloc, tmp, "harness")});
    std.debug.print("TestBddSchemas OK\n", .{});
}

fn join(alloc: std.mem.Allocator, a: []const u8, b: []const u8) []const u8 {
    return std.fs.path.join(alloc, &.{ a, b }) catch unreachable;
}

fn allocPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, fmt, args) catch unreachable;
}

fn writeFile(path: []const u8, content: []const u8) void {
    const f = std.fs.cwd().createFile(path, .{}) catch |e| {
        std.debug.print("create {s}: {}\n", .{ path, e });
        std.process.exit(1);
    };
    defer f.close();
    f.writeAll(content) catch std.process.exit(1);
}

fn run(alloc: std.mem.Allocator, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, alloc);
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        std.debug.print("spawn {s}: {}\n", .{ argv[0], e });
        std.process.exit(1);
    };
    util.check(term == .Exited and term.Exited == 0, "command failed");
}

fn capture(alloc: std.mem.Allocator, argv: []const []const u8) []const u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |e| {
        std.debug.print("spawn {s}: {}\n", .{ argv[0], e });
        std.process.exit(1);
    };
    const out = child.stdout.?.readToEndAlloc(alloc, 1 << 24) catch unreachable;
    const term = child.wait() catch unreachable;
    util.check(term == .Exited and term.Exited == 0, "harness failed");
    return out;
}
