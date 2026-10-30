<?php
// Kafka proxy end-to-end: generated PHP client -> Rust
// kafka_proxy (--tcp) -> Apache Kafka / Redpanda.
//
// Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
// kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
// Skipped otherwise, so the plain `make test-php` run stays
// broker-free.

require_once __DIR__ . "/test_util.php";
require_once dirname(__DIR__) . "/grpcdc/kafka_pb.php";
require_once dirname(__DIR__) . "/grpcdc/kafka_grpc_dc.php";

final class TestKafkaE2E
{
    public static function run(): void
    {
        $addr = getenv("KAFKA_E2E_PROXY_ADDR");
        if ($addr === false || $addr === "") {
            echo "TestKafkaE2E SKIP (KAFKA_E2E_PROXY_ADDR not set)\n";
            return;
        }
        $pos = strrpos($addr, ":");
        $host = substr($addr, 0, $pos);
        $port = (int) substr($addr, $pos + 1);
        $client = new \KafkaGrpcDc\KafkaClient(
            new \Grpcdc\Channel(\Grpcdc\SidecarTransport::connect($host, $port))
        );

        $withTopic = function (callable $block) use ($client): void {
            $topic = "php-kafka-e2e-" . bin2hex(random_bytes(8));
            try {
                $created = $client->CreateTopics(new \KafkaPb\CreateTopicsRequest(
                    topics: [new \KafkaPb\NewTopic(name: $topic, numPartitions: 1, replicationFactor: 1)],
                    timeoutMs: 15000
                ));
                T::assertEq(array_map(fn($r) => $r->errorCode, $created->results), [0], "create topic");
                $deadline = microtime(true) + 15;
                while (true) {
                    $latest = $client->ListOffsets(new \KafkaPb\ListOffsetsRequest(topic: $topic, partition: 0, timestamp: -1));
                    if ($latest->errorCode === 0) {
                        break;
                    }
                    if (microtime(true) > $deadline) {
                        throw new Exception("topic not visible");
                    }
                    usleep(250000);
                }
                $block($topic);
            } finally {
                try {
                    $client->DeleteTopics(new \KafkaPb\DeleteTopicsRequest(topics: [$topic]));
                } catch (Throwable) {
                    // best effort
                }
            }
        };

        $produce = function (string $topic, array $values) use ($client): array {
            $offsets = [];
            foreach ($values as $value) {
                $resp = $client->Produce(new \KafkaPb\ProduceRequest(
                    topic: $topic,
                    partition: 0,
                    records: [new \KafkaPb\Record(key: "k-" . $value, value: $value)]
                ));
                T::assertEq($resp->errorCode, 0, "produce error");
                $offsets[] = $resp->baseOffset;
            }
            return $offsets;
        };
        $consume = function (string $topic, int $offset, int $count) use ($client): array {
            $got = [];
            $stream = $client->Consume(new \KafkaPb\ConsumeRequest(topic: $topic, partition: 0, offset: $offset, maxRecords: $count));
            foreach ($stream->iterate() as $chunk) {
                T::assertEq($chunk->errorCode, 0, "consume error");
                foreach ($chunk->records as $rec) {
                    $got[] = $rec;
                }
                if (count($got) >= $count) {
                    break;
                }
            }
            return $got;
        };
        $values = fn(array $records): array => array_map(fn($r) => $r->value, $records);

        $withTopic(function (string $topic) use ($client, $produce, $consume, $values): void {
            T::assertEq($produce($topic, ["v0", "v1", "v2"]), [0, 1, 2], "roundtrip offsets");
            $latest = $client->ListOffsets(new \KafkaPb\ListOffsetsRequest(topic: $topic, partition: 0, timestamp: -1));
            T::assertEq([$latest->offset, $latest->errorCode], [3, 0], "latest offset");
            $got = $consume($topic, 0, 3);
            T::assertEq($values($got), ["v0", "v1", "v2"], "roundtrip values");
            T::assertEq(array_map(fn($r) => $r->key, $got), ["k-v0", "k-v1", "k-v2"], "roundtrip keys");
        });

        $withTopic(function (string $topic) use ($produce, $consume, $values): void {
            $want = [];
            for ($i = 0; $i < 10; $i++) {
                $want[] = sprintf("seq-%02d", $i);
            }
            T::assertEq($produce($topic, $want), range(0, 9), "ordering offsets");
            T::assertEq($values($consume($topic, 0, 10)), $want, "ordering values");
        });

        $withTopic(function (string $topic) use ($produce, $consume, $values): void {
            $produce($topic, ["a", "b", "c", "d"]);
            T::assertEq($values($consume($topic, 0, 2)), ["a", "b"], "resume first");
            T::assertEq($values($consume($topic, 2, 2)), ["c", "d"], "resume rest");
        });
        echo "TestKafkaE2E OK\n";
    }
}
