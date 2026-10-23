const std = @import("std");
const util = @import("test_util.zig");

/// Generated Zig message types (<base>_messages.zig) from the
/// native protoc-gen-grpc-dc-zig plugin: kitchen-sink round-trip
/// plus a protoc oracle — protoc's own --encode bytes must decode
/// to the same message and re-encode semantically identically.
pub fn testPbMessages(alloc: std.mem.Allocator) void {
    const kitchen_text =
        \\d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
        \\f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
        \\blob: "\x01\x02\x03" color: GREEN
        \\nested { note: "n" level: 3 }
        \\item { sku: "abc" quantity: 2 }
        \\nums: [1, -2, 300] words: ["a", "", "bc"]
        \\manys { note: "m" level: 1 }
        \\vals: [0.5, -1.25]
        \\counts { key: "x" value: 1 } counts { key: "y" value: -2 }
        \\by_id { key: 7 value { note: "z" level: 9 } }
        \\text: "chosen" big_negative: -9007199254740993 neg32: -123456
        \\
    ;

    const harness =
        \\const std = @import("std");
        \\const kitchen = @import("kitchen_messages.zig");
        \\const common = @import("common_messages.zig");
        \\
        \\fn fail(msg: []const u8) noreturn {
        \\    std.debug.print("FAIL: {s}\n", .{msg});
        \\    std.process.exit(1);
        \\}
        \\
        \\fn make(alloc: std.mem.Allocator) kitchen.Kitchen {
        \\    const nested = alloc.create(kitchen.Nested) catch unreachable;
        \\    nested.* = .{ .note = "n", .level = 3 };
        \\    const item = alloc.create(common.Item) catch unreachable;
        \\    item.* = .{ .sku = "abc", .quantity = 2 };
        \\    const m = kitchen.Nested{ .note = "m", .level = 1 };
        \\    const z = kitchen.Nested{ .note = "z", .level = 9 };
        \\    const counts: [2]kitchen.Kitchen_CountsEntry = .{
        \\        .{ .key = "x", .value = 1 },
        \\        .{ .key = "y", .value = -2 },
        \\    };
        \\    const by_id: [1]kitchen.Kitchen_ByIdEntry = .{
        \\        .{ .key = 7, .value = z },
        \\    };
        \\    return .{
        \\        .d = 1.5, .f = 2.5, .i32 = -3, .i64 = -4, .u32 = 5, .u64 = 6,
        \\        .s32 = -7, .s64 = -8, .f32 = 9, .f64 = 10, .sf32 = -11, .sf64 = -12,
        \\        .flag = true, .name = "sink", .blob = "\x01\x02\x03",
        \\        .color = .GREEN,
        \\        .nested = nested,
        \\        .item = item,
        \\        .nums = &.{ 1, -2, 300 },
        \\        .words = &.{ "a", "", "bc" },
        \\        .manys = &.{m},
        \\        .vals = &.{ 0.5, -1.25 },
        \\        .counts = &counts,
        \\        .by_id = &by_id,
        \\        .text = "chosen", .big_negative = -9007199254740993, .neg32 = -123456,
        \\    };
        \\}
        \\
        \\fn checkSame(a: kitchen.Kitchen, b: kitchen.Kitchen) void {
        \\    var ok = a.d == b.d and a.f == b.f and a.i32 == b.i32 and a.i64 == b.i64
        \\        and a.u32 == b.u32 and a.u64 == b.u64 and a.s32 == b.s32 and a.s64 == b.s64
        \\        and a.f32 == b.f32 and a.f64 == b.f64 and a.sf32 == b.sf32 and a.sf64 == b.sf64
        \\        and a.flag == b.flag and std.mem.eql(u8, a.name, b.name)
        \\        and std.mem.eql(u8, a.blob, b.blob) and a.color == b.color
        \\        and std.mem.eql(u8, a.nested.?.note, b.nested.?.note) and a.nested.?.level == b.nested.?.level
        \\        and std.mem.eql(u8, a.item.?.sku, b.item.?.sku) and a.item.?.quantity == b.item.?.quantity
        \\        and std.mem.eql(i32, a.nums, b.nums)
        \\        and a.words.len == b.words.len
        \\        and a.manys.len == b.manys.len and std.mem.eql(u8, a.manys[0].note, b.manys[0].note)
        \\        and a.vals.len == b.vals.len and a.vals[0] == b.vals[0]
        \\        and a.counts.len == b.counts.len
        \\        and a.by_id.len == b.by_id.len
        \\        and std.mem.eql(u8, a.text, b.text) and a.big_negative == b.big_negative and a.neg32 == b.neg32;
        \\    for (a.words, b.words) |x, y| ok = ok and std.mem.eql(u8, x, y);
        \\    for (a.counts) |e| {
        \\        var found = false;
        \\        for (b.counts) |o| {
        \\            if (std.mem.eql(u8, e.key, o.key) and e.value == o.value) found = true;
        \\        }
        \\        ok = ok and found;
        \\    }
        \\    ok = ok and std.mem.eql(u8, a.by_id[0].value.note, b.by_id[0].value.note);
        \\    if (!ok) fail("mismatch");
        \\}
        \\
        \\pub fn main() !void {
        \\    var dba: std.heap.DebugAllocator(.{}) = .init;
        \\    const alloc = dba.allocator();
        \\    const args = try std.process.argsAlloc(alloc);
        \\    const k = make(alloc);
        \\    if (std.mem.eql(u8, args[1], "roundtrip")) {
        \\        var back = kitchen.Kitchen{};
        \\        back.unmarshalDc(alloc, k.marshalDc(alloc));
        \\        checkSame(back, k);
        \\        var empty = kitchen.Kitchen{};
        \\        if (empty.marshalDc(alloc).len != 0) fail("empty");
        \\        var both = kitchen.Kitchen{ .text = "a", .code = 7 };
        \\        var both_back = kitchen.Kitchen{};
        \\        both_back.unmarshalDc(alloc, both.marshalDc(alloc));
        \\        if (both_back.text.len != 0 or both_back.code != 7) fail("oneof encode clearing");
        \\        std.debug.print("roundtrip OK\n", .{});
        \\        return;
        \\    }
        \\    const bytes = try std.fs.cwd().readFileAlloc(alloc, args[2], 1 << 24);
        \\    var from = kitchen.Kitchen{};
        \\    from.unmarshalDc(alloc, bytes);
        \\    checkSame(from, k);
        \\    var again = kitchen.Kitchen{};
        \\    again.unmarshalDc(alloc, from.marshalDc(alloc));
        \\    checkSame(again, from);
        \\    std.debug.print("oracle OK\n", .{});
        \\}
        \\
    ;

    var root: []const u8 = "..";
    if (!exists(root, "webapp/testdata/kitchen.proto")) root = ".";
    const testdata = join(alloc, root, "webapp/testdata");
    var tmp: []const u8 = "/tmp/grpcdc-zig-pb";
    _ = &tmp;
    run(alloc, &.{ "rm", "-rf", tmp });
    const gen = join(alloc, tmp, "gen");
    run(alloc, &.{ "mkdir", "-p", gen });
    run(alloc, &.{
        "protoc",
        allocPrint(alloc, "--plugin=protoc-gen-grpc-dc-zig={s}/bin/protoc-gen-grpc-dc-zig", .{root}),
        allocPrint(alloc, "--grpc-dc-zig_out={s}", .{gen}),
        "-I", testdata, "common.proto", "kitchen.proto",
    });
    std.fs.cwd().deleteFile(join(alloc, gen, "common_grpc_dc.zig")) catch {};
    std.fs.cwd().deleteFile(join(alloc, gen, "kitchen_grpc_dc.zig")) catch {};
    writeFile(join(alloc, gen, "main.zig"), harness);
    run(alloc, &.{ "zig", "build-exe",
        join(alloc, gen, "main.zig"),
        allocPrint(alloc, "-femit-bin={s}/harness", .{tmp}) });
    const out1 = capture(alloc, &.{ join(alloc, tmp, "harness"), "roundtrip" });
    util.check(std.mem.indexOf(u8, out1, "roundtrip OK") != null, "roundtrip");
    writeFile(join(alloc, tmp, "kitchen.txt"), kitchen_text);
    const bin = join(alloc, tmp, "protoc.bin");
    runShell(alloc, allocPrint(alloc,
        "protoc --encode=kitchen.v1.Kitchen -I {s} kitchen.proto < {s}/kitchen.txt > {s}",
        .{ testdata, tmp, bin }));
    const out2 = capture(alloc, &.{ join(alloc, tmp, "harness"), "oracle", bin });
    util.check(std.mem.indexOf(u8, out2, "oracle OK") != null, "oracle");
    std.debug.print("TestPbMessages OK\n", .{});
}

fn exists(root: []const u8, rel: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel }) catch return false;
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
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
    child.stderr_behavior = .Pipe;
    child.spawn() catch std.process.exit(1);
    const out = child.stdout.?.readToEndAlloc(alloc, 1 << 24) catch std.process.exit(1);
    const err = child.stderr.?.readToEndAlloc(alloc, 1 << 24) catch "";
    const term = child.wait() catch std.process.exit(1);
    util.check(term == .Exited and term.Exited == 0, "capture failed");
    return std.mem.concat(alloc, u8, &.{ out, err }) catch unreachable;
}

fn runShell(alloc: std.mem.Allocator, cmd: []const u8) void {
    run(alloc, &.{ "bash", "-c", cmd });
}
