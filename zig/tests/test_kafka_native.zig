const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const km = examples.kafka_messages;

// Kafka native end-to-end: generated Zig messages ->
// libkafka_native in-process (no proxy, no gRPC hop).
//
// Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
// GRPC_DC_KAFKA_NATIVE_LIB=path/to/libkafka_native.so.
// Skipped otherwise.

pub fn testKafkaNative(alloc: std.mem.Allocator) void {
    const broker = std.process.getEnvVarOwned(alloc, "KAFKA_E2E_BROKER") catch {
        std.debug.print("TestKafkaNative SKIP (KAFKA_E2E_BROKER not set)\n", .{});
        return;
    };
    defer alloc.free(broker);

    var client = grpcdc.kafka_native.KafkaNativeClient.init(alloc, broker, "grpc-dc-kafka-native-zig") catch {
        util.check(false, "kafka native init");
        return;
    };
    defer client.deinit();
    const kc = client.typed(km);

    var rand_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const topic = std.fmt.allocPrint(alloc, "zig-kafka-native-{x}", .{rand_bytes}) catch unreachable;
    defer alloc.free(topic);
    defer {
        _ = kc.deleteTopics(.{ .topics = &.{topic}, .timeout_ms = 15000 }) catch {};
    }

    const created = kc.createTopics(.{
        .topics = &.{.{ .name = topic, .num_partitions = 1, .replication_factor = 1 }},
        .timeout_ms = 15000,
    }) catch {
        util.check(false, "createTopics call");
        return;
    };
    util.check(created.results.len == 1 and created.results[0].error_code == 0, "create topic");

    const produced = kc.produce(.{
        .topic = topic,
        .partition = 0,
        .records = &.{
            .{ .value = "one" },
            .{ .value = "two" },
            .{ .value = "three" },
        },
    }) catch {
        util.check(false, "produce call");
        return;
    };
    util.check(produced.error_code == 0, "produce error_code");

    var stream = kc.consume(.{
        .topic = topic,
        .partition = 0,
        .offset = -2,
        .max_records = 10,
        .max_wait_ms = 2000,
    }) catch {
        util.check(false, "consume call");
        return;
    };
    defer stream.close();
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(alloc);
    while (values.items.len < 3) {
        const chunk = (stream.next(km.ConsumeResponse) catch {
            util.check(false, "consume next");
            return;
        }) orelse break;
        util.check(chunk.error_code == 0, "consume error_code");
        for (chunk.records) |r| values.append(alloc, r.value) catch {};
    }
    util.check(values.items.len == 3, "consumed 3 records");
    if (values.items.len == 3) {
        util.check(std.mem.eql(u8, values.items[0], "one"), "value[0]");
        util.check(std.mem.eql(u8, values.items[1], "two"), "value[1]");
        util.check(std.mem.eql(u8, values.items[2], "three"), "value[2]");
    }

    const latest = kc.listOffsets(.{ .topic = topic, .partition = 0, .timestamp = -1 }) catch {
        util.check(false, "listOffsets call");
        return;
    };
    util.check(latest.error_code == 0 and latest.offset == 3, "listOffsets offset==3");
    std.debug.print("TestKafkaNative OK\n", .{});
}
