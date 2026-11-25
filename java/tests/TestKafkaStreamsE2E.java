package tests;

import grpcdc.Channel;
import grpcdc.KafkaStreamsScenarios;
import grpcdc.SidecarTransport;
import grpcdc.kafka.streams.v1.CreateTopologyRequest;
import grpcdc.kafka.streams.v1.DeleteTopologyRequest;
import grpcdc.kafka.streams.v1.GetStoreValueRequest;
import grpcdc.kafka.streams.v1.GetStoreValueResponse;
import grpcdc.kafka.streams.v1.Kafka_streamsGrpcDc;
import grpcdc.kafka.streams.v1.Operator;
import grpcdc.kafka.streams.v1.Step;
import grpcdc.kafka.streams.v1.Topology;
import grpcdc.kafka.streams.v1.TopologyInfo;
import grpcdc.kafka.v1.ConsumeRequest;
import grpcdc.kafka.v1.CreateTopicsRequest;
import grpcdc.kafka.v1.DeleteTopicsRequest;
import grpcdc.kafka.v1.KafkaGrpcDc;
import grpcdc.kafka.v1.NewTopic;
import grpcdc.kafka.v1.ProduceRequest;
import grpcdc.kafka.v1.Record;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Kafka Streams generated-scenario interpreter (Java): runs
 * the racket/kafka-streams-spec.rkt table stamped into
 * KafkaStreamsScenarios. Env-gated like the other kafka
 * suites (KAFKA_E2E_PROXY_ADDR).
 */
public final class TestKafkaStreamsE2E {
    private TestKafkaStreamsE2E() {}

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }

    private static Map<String, String> parsePairs(String s) {
        Map<String, String> out = new HashMap<>();
        if (s.isEmpty()) {
            return out;
        }
        for (String kv : s.split(";")) {
            int eq = kv.indexOf('=');
            out.put(kv.substring(0, eq), kv.substring(eq + 1));
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        String addr = System.getenv("KAFKA_E2E_PROXY_ADDR");
        if (addr == null || addr.isEmpty()) {
            System.out.println("TestKafkaStreamsE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)");
            return;
        }
        int sep = addr.lastIndexOf(':');
        Channel channel = new Channel(
                SidecarTransport.connect(addr.substring(0, sep),
                        Integer.parseInt(addr.substring(sep + 1))));
        KafkaGrpcDc.KafkaClient kafka = new KafkaGrpcDc.KafkaClient(channel);
        Kafka_streamsGrpcDc.KafkaStreamsClient streams =
                new Kafka_streamsGrpcDc.KafkaStreamsClient(channel);

        for (Object[] raw : KafkaStreamsScenarios.SCENARIOS) {
            String scenarioName = (String) raw[0];
            String[][] chainRaw = (String[][]) raw[1];
            String[] lines = (String[]) raw[2];
            Map<String, String> storeWant = parsePairs((String) raw[3]);
            Map<String, String> sinkWant = parsePairs((String) raw[4]);
            String suffix = "%012x".formatted(new SecureRandom().nextLong());
            String source = "java-streams-in-" + suffix;
            String sink = "java-streams-out-" + suffix;
            String name = "java-" + scenarioName + "-" + suffix;
            try {
                for (String topic : List.of(source, sink)) {
                    var created = kafka.CreateTopics(
                            new CreateTopicsRequest(List.of(new NewTopic(topic, 1, 1)), 15000, false));
                    check(created.results.size() == 1 && created.results.get(0).errorCode == 0,
                            "create topic " + topic);
                }
                java.util.List<Step> steps = new java.util.ArrayList<>();
                for (String[] st : chainRaw) {
                    Step step = new Step();
                    step.operator = Operator.valueOf(st[0]);
                    step.param = st[1];
                    step.aggregator = grpcdc.kafka.streams.v1.Aggregator.fromNumber(Integer.parseInt(st[2]));
                    steps.add(step);
                }
                Topology topo = new Topology();
                topo.name = name;
                topo.sourceTopic = source;
                topo.sinkTopic = sink;
                topo.steps = steps;
                TopologyInfo info = streams.CreateTopology(new CreateTopologyRequest(topo));
                check("RUNNING".equals(info.state), "topology running: " + info.state);
                for (String line : lines) {
                    var resp = kafka.Produce(new ProduceRequest(
                            source, 0, List.of(new Record(new byte[0], line.getBytes(StandardCharsets.UTF_8), List.of(), 0L, false)), grpcdc.kafka.v1.Acks.ACKS_UNSPECIFIED, 0,
                            grpcdc.kafka.v1.Compression.COMPRESSION_NONE, "", ""));
                    check(resp.errorCode == 0, "produce");
                }
                for (Map.Entry<String, String> e : storeWant.entrySet()) {
                    long want = Long.parseLong(e.getValue());
                    GetStoreValueResponse got = null;
                    long deadline = System.currentTimeMillis() + 20000;
                    while (true) {
                        got = streams.GetStoreValue(new GetStoreValueRequest(name, e.getKey()));
                        if (got.found && got.value == want) {
                            break;
                        }
                        check(System.currentTimeMillis() < deadline,
                                "store " + e.getKey() + " want " + want + " got " + (got == null ? null : got.value));
                        Thread.sleep(250);
                    }
                }
                // Final sink values.
                Map<String, String> fin = new HashMap<>();
                var stream = kafka.Consume(new ConsumeRequest(sink, 0, 0, 200, 0, 0, false));
                long deadline = System.currentTimeMillis() + 20000;
                while (fin.size() < sinkWant.size() && System.currentTimeMillis() < deadline) {
                    var chunk = stream.recv();
                    if (chunk == null) {
                        break;
                    }
                    for (var r : chunk.records) {
                        fin.put(new String(r.key, StandardCharsets.UTF_8),
                                new String(r.value, StandardCharsets.UTF_8));
                    }
                }
                check(fin.equals(sinkWant), "sink final: got " + fin + " want " + sinkWant);
                System.out.println("ok: java streams scenario " + scenarioName);
            } finally {
                try {
                    streams.DeleteTopology(new DeleteTopologyRequest(name));
                } catch (Exception ignored) {
                }
                try {
                    kafka.DeleteTopics(new DeleteTopicsRequest(List.of(source, sink), 0));
                } catch (Exception ignored) {
                }
            }
        }
        System.out.println("TestKafkaStreamsE2E PASS");
    }
}
