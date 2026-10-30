package tests;

import grpcdc.Channel;
import grpcdc.SidecarTransport;
import grpcdc.kafka.v1.ConsumeRequest;
import grpcdc.kafka.v1.ConsumeResponse;
import grpcdc.kafka.v1.CreateTopicsRequest;
import grpcdc.kafka.v1.DeleteTopicsRequest;
import grpcdc.kafka.v1.FetchedRecord;
import grpcdc.kafka.v1.KafkaGrpcDc;
import grpcdc.kafka.v1.ListOffsetsRequest;
import grpcdc.kafka.v1.ListOffsetsResponse;
import grpcdc.kafka.v1.NewTopic;
import grpcdc.kafka.v1.ProduceRequest;
import grpcdc.kafka.v1.ProduceResponse;
import grpcdc.kafka.v1.Record;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;

/**
 * Kafka proxy end-to-end: generated Java client -> Rust
 * kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
 *
 * Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
 * kafka_proxy (see scripts/kafka-e2e.sh / make test-kafka).
 * Skipped otherwise, so the plain `make test-java` run stays
 * broker-free.
 */
public final class TestKafkaE2E {
    private TestKafkaE2E() {}

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static String createTopic(KafkaGrpcDc.KafkaClient client) throws Exception {
        String suffix = "%016x".formatted(new SecureRandom().nextLong());
        String topic = "java-kafka-e2e-" + suffix;
        var created = client.CreateTopics(
                new CreateTopicsRequest(List.of(new NewTopic(topic, 1, 1)), 15000, false));
        check(created.results.size() == 1 && created.results.get(0).errorCode == 0,
                "create topic");
        long deadline = System.currentTimeMillis() + 15000;
        while (true) {
            ListOffsetsResponse latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1, false));
            if (latest.errorCode == 0) {
                return topic;
            }
            check(System.currentTimeMillis() < deadline, "topic not visible");
            Thread.sleep(250);
        }
    }

    private static List<Long> produce(
            KafkaGrpcDc.KafkaClient client, String topic, List<String> values) throws Exception {
        List<Long> offsets = new ArrayList<>();
        for (String value : values) {
            ProduceResponse resp = client.Produce(new ProduceRequest(
                    topic, 0,
                    List.of(new Record(
                            ("k-" + value).getBytes(StandardCharsets.UTF_8),
                            value.getBytes(StandardCharsets.UTF_8),
                            List.of(), 0, false)),
                    null, 0, null, "", ""));
            check(resp.errorCode == 0, "produce error " + resp.errorCode);
            offsets.add(resp.baseOffset);
        }
        return offsets;
    }

    private static List<FetchedRecord> consume(
            KafkaGrpcDc.KafkaClient client, String topic, long offset, int count)
            throws Exception {
        List<FetchedRecord> got = new ArrayList<>();
        try (var stream = client.Consume(new ConsumeRequest(topic, 0, offset, count, 0, 0, false))) {
            while (got.size() < count) {
                ConsumeResponse chunk = stream.recv();
                check(chunk.errorCode == 0, "consume error " + chunk.errorCode);
                got.addAll(chunk.records);
            }
        }
        return got;
    }

    private static List<String> values(List<FetchedRecord> records) {
        return records.stream()
                .map(r -> new String(r.value, StandardCharsets.UTF_8))
                .toList();
    }

    public static void main(String[] args) throws Exception {
        String addr = System.getenv("KAFKA_E2E_PROXY_ADDR");
        if (addr == null || addr.isEmpty()) {
            System.out.println("TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)");
            return;
        }
        int sep = addr.lastIndexOf(':');
        KafkaGrpcDc.KafkaClient client = new KafkaGrpcDc.KafkaClient(new Channel(
                SidecarTransport.connect(addr.substring(0, sep),
                        Integer.parseInt(addr.substring(sep + 1)))));

        String topic = createTopic(client);
        try {
            check(produce(client, topic, List.of("v0", "v1", "v2")).equals(List.of(0L, 1L, 2L)),
                    "roundtrip offsets");
            ListOffsetsResponse latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1, false));
            check(latest.offset == 3 && latest.errorCode == 0, "latest offset");
            List<FetchedRecord> got = consume(client, topic, 0, 3);
            check(values(got).equals(List.of("v0", "v1", "v2")), "roundtrip values");
            check(got.stream()
                            .map(r -> new String(r.key, StandardCharsets.UTF_8))
                            .toList()
                            .equals(List.of("k-v0", "k-v1", "k-v2")),
                    "roundtrip keys");
        } finally {
            client.DeleteTopics(new DeleteTopicsRequest(List.of(topic), 0));
        }

        topic = createTopic(client);
        try {
            List<String> want = new ArrayList<>();
            List<Long> wantOffsets = new ArrayList<>();
            for (int i = 0; i < 10; i++) {
                want.add("seq-%02d".formatted(i));
                wantOffsets.add((long) i);
            }
            check(produce(client, topic, want).equals(wantOffsets), "ordering offsets");
            check(values(consume(client, topic, 0, 10)).equals(want), "ordering values");
        } finally {
            client.DeleteTopics(new DeleteTopicsRequest(List.of(topic), 0));
        }

        topic = createTopic(client);
        try {
            produce(client, topic, List.of("a", "b", "c", "d"));
            check(values(consume(client, topic, 0, 2)).equals(List.of("a", "b")), "resume first");
            check(values(consume(client, topic, 2, 2)).equals(List.of("c", "d")), "resume rest");
        } finally {
            client.DeleteTopics(new DeleteTopicsRequest(List.of(topic), 0));
        }
        System.out.println("TestKafkaE2E OK");
    }
}
