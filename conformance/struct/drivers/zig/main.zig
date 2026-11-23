const std = @import("std");
const messages = @import("msgs_messages.zig");
const structs = @import("msgs_struct.zig");
const messages2 = @import("msgs2_messages.zig");
const structs2 = @import("msgs2_struct.zig");

const Inner = messages.Inner;
const Outer = messages.Outer;
const Hue = messages.Hue;
const OuterStruct = structs.OuterStruct;

fn parseHex(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, s.len / 2);
    for (out, 0..) |*b, i| {
        b.* = try std.fmt.parseInt(u8, s[2 * i .. 2 * i + 2], 16);
    }
    return out;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    const golden = try parseHex(alloc, args[1]);

    const inner0 = try alloc.create(Inner);
    inner0.* = Inner{ .v = "x", .n = -3 };
    const b_second = Inner{ .v = "second" };
    const b_first = Inner{ .v = "first", .n = 9 };
    const iv1 = Inner{ .v = "i1" };
    const iv2 = Inner{ .v = "i2" };
    const iv3 = Inner{ .v = "i3" };

    const by_name = [_]messages.Outer_ByNameEntry{
        .{ .key = "b", .value = b_second },
        .{ .key = "a", .value = b_first },
    };
    const by_id = [_]messages.Outer_ByIdEntry{
        .{ .key = 7, .value = "seven" },
        .{ .key = 2, .value = "two" },
    };
    const nums = [_]i32{ 1, -2, 300 };
    const names = [_][]const u8{ "n1", "n2" };
    const inners = [_]Inner{ iv1, iv2, iv3 };

    const m = Outer{
        .inner = inner0,
        .hue = .RED,
        .nums = &nums,
        .by_name = &by_name,
        .s = "picked",
        .blob = &[_]u8{ 1, 2, 3 },
        .names = &names,
        .inners = &inners,
        .by_id = &by_id,
        .score = 3.5,
        .ratio = 0.25,
        .flag = true,
        .stamp = 123456789,
        .delta = -77,
    };

    const got = try OuterStruct.marshal(&m, alloc);
    if (!std.mem.eql(u8, got, golden)) {
        std.debug.print("MARSHAL_MISMATCH\n got {x}\nwant {x}\n", .{ got, golden });
        std.process.exit(1);
    }
    const back = try OuterStruct.unmarshal(alloc, golden);
    const rt = try OuterStruct.marshal(&back, alloc);
    if (!std.mem.eql(u8, rt, golden)) {
        std.debug.print("ROUNDTRIP_MISMATCH\n", .{});
        std.process.exit(1);
    }

    const P2 = messages2.P2;
    const P2Struct = structs2.P2Struct;
    const golden2 = try parseHex(alloc, args[2]);
    const nums2 = [_]i32{ 5, -6 };
    const p2 = P2{
        .name = "req",
        .count = 42,
        .greeting = "hi",
        .enabled = false,
        .ratio = 2.5,
        .nums = &nums2,
        .ext_note = "note!",
    };
    const got2 = try P2Struct.marshal(&p2, alloc);
    if (!std.mem.eql(u8, got2, golden2)) {
        std.debug.print("MARSHAL2_MISMATCH\n got {x}\nwant {x}\n", .{ got2, golden2 });
        std.process.exit(1);
    }
    const back2 = try P2Struct.unmarshal(alloc, golden2);
    const rt2 = try P2Struct.marshal(&back2, alloc);
    if (!std.mem.eql(u8, rt2, golden2)) {
        std.debug.print("ROUNDTRIP2_MISMATCH\n", .{});
        std.process.exit(1);
    }
    std.debug.print("DECODE_OK\n", .{});
}
