package tests;

import grpcdc.KafkaNative;
import grpcdc.kafka.v1.ConsumeRequest;
import grpcdc.kafka.v1.CreateTopicsRequest;
import grpcdc.kafka.v1.DeleteTopicsRequest;
import grpcdc.kafka.v1.ListOffsetsRequest;
import grpcdc.kafka.v1.MetadataRequest;
import grpcdc.kafka.v1.NewTopic;
import grpcdc.kafka.v1.ProduceRequest;
import grpcdc.kafka.v1.Record;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;

/**
 * Kafka native end-to-end: generated Java messages ->
 * libkafka_native in-process via the JNI shim (no proxy,
 * no gRPC hop).
 *
 * Env-gated: set KAFKA_E2E_BROKER=host:port of a broker,
 * GRPC_DC_KAFKA_NATIVE_LIB=path (for the runner to locate
 * artifacts), and GRPC_DC_KAFKA_NATIVE_JNI=path to the
 * built libkafka_native_jni.so. Skipped otherwise.
 */
public final class TestKafkaNative {
    private TestKafkaNative() {}

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    public static void main(String[] args) throws Exception {
        String broker = System.getenv("KAFKA_E2E_BROKER");
        String jni = System.getenv("GRPC_DC_KAFKA_NATIVE_JNI");
        if (broker == null || broker.isEmpty() || jni == null || jni.isEmpty()) {
            System.out.println("TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_JNI not set)");
            return;
        }
        String topic = "java-kafka-native-%016x".formatted(new SecureRandom().nextLong());
        try (KafkaNative client = new KafkaNative(broker)) {
            try {
                var created = client.CreateTopics(
                        new CreateTopicsRequest(List.of(new NewTopic(topic, 1, 1)), 15000, false));
                check(created.results.size() == 1 && created.results.get(0).errorCode == 0,
                        "create topic");

                long deadline = System.currentTimeMillis() + 15000;
                while (true) {
                    var meta = client.Metadata(new MetadataRequest(List.of(topic), false));
                    boolean ready = meta.topics.stream()
                            .anyMatch(t -> t.name.equals(topic) && !t.partitions.isEmpty());
                    if (ready) {
                        break;
                    }
                    check(System.currentTimeMillis() < deadline, "topic not visible");
                    Thread.sleep(250);
                }

                var records = new ArrayList<Record>();
                for (String v : List.of("one", "two", "three")) {
                    records.add(new Record(
                            null, v.getBytes(StandardCharsets.UTF_8), List.of(), 0, false));
                }
                var produced = client.Produce(new ProduceRequest(
                        topic, 0, records, null, 0, null, "", ""));
                check(produced.errorCode == 0, "produce: " + produced.errorCode);

                var values = new ArrayList<String>();
                var stream = client.Consume(new ConsumeRequest(topic, 0, -2, 10, 2000, 0, false));
                while (values.size() < 3 && stream.hasNext()) {
                    var chunk = stream.next();
                    check(chunk.errorCode == 0, "consume error: " + chunk.errorCode);
                    for (var r : chunk.records) {
                        values.add(new String(r.value, StandardCharsets.UTF_8));
                    }
                }
                check(values.equals(List.of("one", "two", "three")), "values: " + values);

                var latest = client.ListOffsets(new ListOffsetsRequest(topic, 0, -1, false));
                check(latest.errorCode == 0 && latest.offset == 3, "listOffsets");
                System.out.println("TestKafkaNative OK");
            } finally {
                try {
                    client.DeleteTopics(new DeleteTopicsRequest(List.of(topic), 15000));
                } catch (RuntimeException ignored) {
                    // best effort
                }
            }
        }
    }
}
