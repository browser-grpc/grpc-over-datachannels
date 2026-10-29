const std = @import("std");
const grpcdc = @import("grpcdc");
const examples = @import("examples");
const util = @import("test_util.zig");

const Channel = grpcdc.channel.Channel;
const kafka = examples.kafka_grpc_dc;
const km = examples.kafka_messages;

// Kafka proxy end-to-end: generated Zig client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-zig` run stays
// broker-free.

fn unwrap(comptime T: type, result: anytype, what: []const u8) T {
    return switch (result) {
        .ok => |v| v,
        .status => |st| {
            util.checkFmt(false, "{s} status {d} {s}", .{ what, st.code, st.message });
            unreachable;
        },
    };
}

fn createTopic(client: *kafka.KafkaClient, buf: []u8) []const u8 {
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const topic = std.fmt.bufPrint(buf, "zig-kafka-e2e-{s}", .{std.fmt.bytesToHex(rand_bytes, .lower)}) catch unreachable;
    const topics = [_]km.NewTopic{.{ .name = topic, .num_partitions = 1, .replication_factor = 1 }};
    const created = unwrap(km.CreateTopicsResponse, client.createTopics(&.{ .topics = &topics, .timeout_ms = 15000 }, null, null), "createTopics");
    util.check(created.results.len == 1 and created.results[0].error_code == 0, "create topic");
    var waited_ms: u32 = 0;
    while (waited_ms < 15000) {
        const latest = unwrap(km.ListOffsetsResponse, client.listOffsets(&.{ .topic = topic, .partition = 0, .timestamp = -1 }, null, null), "listOffsets");
        if (latest.error_code == 0) return topic;
        std.Thread.sleep(250 * std.time.ns_per_ms);
        waited_ms += 250;
    }
    util.check(false, "topic not visible");
    unreachable;
}

fn produce(client: *kafka.KafkaClient, topic: []const u8, values: []const []const u8, offsets: []i64) void {
    for (values, 0..) |value, i| {
        const key = std.fmt.allocPrint(std.heap.page_allocator, "k-{s}", .{value}) catch unreachable;
        const records = [_]km.Record{.{ .key = key, .value = value }};
        const resp = unwrap(km.ProduceResponse, client.produce(&.{ .topic = topic, .partition = 0, .records = &records }, null, null), "produce");
        util.check(resp.error_code == 0, "produce error");
        offsets[i] = resp.base_offset;
    }
}

fn consume(client: *kafka.KafkaClient, topic: []const u8, offset: i64, count: usize, out: []km.FetchedRecord) usize {
    var stream = unwrap(kafka.KafkaConsumeClient, client.consume(&.{ .topic = topic, .partition = 0, .offset = offset, .max_records = @intCast(count) }, null, null), "consume");
    defer stream.deinit();
    var n: usize = 0;
    while (n < count) {
        switch (stream.recv()) {
            .message => |chunk| {
                util.check(chunk.error_code == 0, "consume error");
                for (chunk.records) |rec| {
                    if (n < out.len) {
                        out[n] = rec;
                        n += 1;
                    }
                }
            },
            .end => break,
            .status => |st| {
                util.checkFmt(false, "consume status {d}", .{st.code});
                break;
            },
        }
    }
    return n;
}

pub fn testKafkaE2E(alloc: std.mem.Allocator) void {
    const addr = std.process.getEnvVarOwned(alloc, "KAFKA_E2E_PROXY_ADDR") catch "";
    if (addr.len == 0) {
        std.debug.print("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)\n", .{});
        return;
    }
    const sep = std.mem.lastIndexOfScalar(u8, addr, ':').?;
    const port = std.fmt.parseInt(u16, addr[sep + 1 ..], 10) catch unreachable;
    const transport = grpcdc.sidecar_transport.SidecarTransport.connect(alloc, addr[0..sep], port) catch unreachable;
    var channel = Channel.init(alloc, transport.transport());
    var client = kafka.KafkaClient.init(&channel);

    var topic_buf: [64]u8 = undefined;

    {
        const topic = createTopic(&client, &topic_buf);
        var offsets: [3]i64 = undefined;
        produce(&client, topic, &.{ "v0", "v1", "v2" }, &offsets);
        util.check(std.mem.eql(i64, &offsets, &.{ 0, 1, 2 }), "roundtrip offsets");
        const latest = unwrap(km.ListOffsetsResponse, client.listOffsets(&.{ .topic = topic, .partition = 0, .timestamp = -1 }, null, null), "listOffsets");
        util.check(latest.offset == 3 and latest.error_code == 0, "latest offset");
        var got: [3]km.FetchedRecord = undefined;
        const n = consume(&client, topic, 0, 3, &got);
        util.check(n == 3, "roundtrip count");
        util.check(std.mem.eql(u8, got[0].value, "v0") and std.mem.eql(u8, got[1].value, "v1") and std.mem.eql(u8, got[2].value, "v2"), "roundtrip values");
        util.check(std.mem.eql(u8, got[0].key, "k-v0") and std.mem.eql(u8, got[2].key, "k-v2"), "roundtrip keys");
        _ = unwrap(km.DeleteTopicsResponse, client.deleteTopics(&.{ .topics = &.{topic} }, null, null), "deleteTopics");
    }
    {
        const topic = createTopic(&client, &topic_buf);
        const want: []const []const u8 = &.{ "seq-00", "seq-01", "seq-02", "seq-03", "seq-04", "seq-05", "seq-06", "seq-07", "seq-08", "seq-09" };
        var offsets: [10]i64 = undefined;
        produce(&client, topic, want, &offsets);
        util.check(std.mem.eql(i64, &offsets, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }), "ordering offsets");
        var got: [10]km.FetchedRecord = undefined;
        const n = consume(&client, topic, 0, 10, &got);
        util.check(n == 10, "ordering count");
        for (want, 0..) |w, i| util.check(std.mem.eql(u8, got[i].value, w), "ordering values");
        _ = unwrap(km.DeleteTopicsResponse, client.deleteTopics(&.{ .topics = &.{topic} }, null, null), "deleteTopics");
    }
    {
        const topic = createTopic(&client, &topic_buf);
        var offsets: [4]i64 = undefined;
        produce(&client, topic, &.{ "a", "b", "c", "d" }, &offsets);
        var first: [2]km.FetchedRecord = undefined;
        util.check(consume(&client, topic, 0, 2, &first) == 2, "resume first count");
        util.check(std.mem.eql(u8, first[0].value, "a") and std.mem.eql(u8, first[1].value, "b"), "resume first");
        var rest: [2]km.FetchedRecord = undefined;
        util.check(consume(&client, topic, 2, 2, &rest) == 2, "resume rest count");
        util.check(std.mem.eql(u8, rest[0].value, "c") and std.mem.eql(u8, rest[1].value, "d"), "resume rest");
        _ = unwrap(km.DeleteTopicsResponse, client.deleteTopics(&.{ .topics = &.{topic} }, null, null), "deleteTopics");
    }
    std.debug.print("TestKafkaE2E OK\n", .{});
}
