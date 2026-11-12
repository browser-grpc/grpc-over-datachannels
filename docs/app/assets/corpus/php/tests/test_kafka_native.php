<?php
// Kafka native end-to-end: generated PHP messages ->
// libkafka_native in-process (no proxy, no gRPC hop).
//
// Env-gated: set KAFKA_E2E_BROKER=host:port of a broker and
// GRPC_DC_KAFKA_NATIVE_LIB=path/to/libkafka_native.so.
// Skipped otherwise.

require_once __DIR__ . "/test_util.php";
require_once dirname(__DIR__) . "/grpcdc/kafka_native.php";

final class TestKafkaNative
{
    public static function run(): void
    {
        $broker = getenv("KAFKA_E2E_BROKER");
        $lib = getenv("GRPC_DC_KAFKA_NATIVE_LIB");
        if ($broker === false || $broker === "" || $lib === false || $lib === "") {
            echo "TestKafkaNative SKIP (KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_LIB not set)\n";
            return;
        }
        $client = new \Grpcdc\KafkaNativeClient($broker);
        $topic = "php-kafka-native-" . bin2hex(random_bytes(8));
        try {
            $created = $client->CreateTopics(new \KafkaPb\CreateTopicsRequest(
                topics: [new \KafkaPb\NewTopic(name: $topic, numPartitions: 1, replicationFactor: 1)],
                timeoutMs: 15000
            ));
            T::assertEq(array_map(fn($r) => $r->errorCode, $created->results), [0], "create topic");
            $deadline = microtime(true) + 15;
            while (true) {
                $meta = $client->Metadata(new \KafkaPb\MetadataRequest(topics: [$topic]));
                $ready = false;
                foreach ($meta->topics as $t) {
                    if ($t->name === $topic && count($t->partitions) > 0) {
                        $ready = true;
                    }
                }
                if ($ready) {
                    break;
                }
                if (microtime(true) > $deadline) {
                    throw new Exception("topic not visible");
                }
                usleep(250000);
            }

            $produced = $client->Produce(new \KafkaPb\ProduceRequest(
                topic: $topic,
                partition: 0,
                records: [
                    new \KafkaPb\Record(value: "one"),
                    new \KafkaPb\Record(value: "two"),
                    new \KafkaPb\Record(value: "three"),
                ]
            ));
            T::assertEq($produced->errorCode, 0, "produce");

            $values = [];
            $stream = $client->Consume(new \KafkaPb\ConsumeRequest(
                topic: $topic, partition: 0, offset: -2, maxRecords: 10, maxWaitMs: 2000));
            try {
                foreach ($stream as $chunk) {
                    T::assertEq($chunk->errorCode, 0, "consume error");
                    foreach ($chunk->records as $r) {
                        $values[] = $r->value;
                    }
                    if (count($values) >= 3) {
                        break;
                    }
                }
            } finally {
                $stream->close();
            }
            T::assertEq($values, ["one", "two", "three"], "roundtrip values");

            $latest = $client->ListOffsets(new \KafkaPb\ListOffsetsRequest(topic: $topic, partition: 0, timestamp: -1));
            T::assertEq([$latest->offset, $latest->errorCode], [3, 0], "latest offset");
            echo "TestKafkaNative OK\n";
        } finally {
            try {
                $client->DeleteTopics(new \KafkaPb\DeleteTopicsRequest(topics: [$topic]));
            } catch (Throwable) {
                // best effort
            }
            $client->close();
        }
    }
}
