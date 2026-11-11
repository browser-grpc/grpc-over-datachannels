"""Native (in-process) Kafka client e2e: grpcdc.kafka_native
drives libkafka_native directly against a broker — no proxy
process, no gRPC hop.

Env-gated: needs KAFKA_E2E_BROKER=host:port (the broker
itself, not a proxy) and GRPC_DC_KAFKA_NATIVE_LIB pointing
at the built libkafka_native shared library. Without them
the suite skips so plain test runs stay green.
"""

import os
import time
import unittest

from grpcdc import kafka_pb
from grpcdc.kafka_native import NativeKafkaClient

BROKER = os.environ.get("KAFKA_E2E_BROKER")
LIB = os.environ.get("GRPC_DC_KAFKA_NATIVE_LIB")


def unique(prefix):
    return f"{prefix}-{time.time_ns()}"


@unittest.skipUnless(BROKER and LIB, "KAFKA_E2E_BROKER / GRPC_DC_KAFKA_NATIVE_LIB unset")
class TestKafkaNative(unittest.TestCase):
    def setUp(self):
        self.client = NativeKafkaClient(BROKER)
        self.topic = unique("grpc-dc-native")
        created = self.client.CreateTopics(kafka_pb.CreateTopicsRequest(
            topics=[kafka_pb.NewTopic(
                name=self.topic, num_partitions=1, replication_factor=1)],
            timeout_ms=30_000))
        self.assertEqual(created.results[0].error_code, 0, created)
        deadline = time.time() + 30
        while time.time() < deadline:
            meta = self.client.Metadata(kafka_pb.MetadataRequest(topics=[self.topic]))
            topics = [t for t in meta.topics if t.name == self.topic]
            if topics and topics[0].partitions:
                break
            time.sleep(0.2)
        else:
            self.fail("topic never became visible")

    def tearDown(self):
        try:
            self.client.DeleteTopics(kafka_pb.DeleteTopicsRequest(
                topics=[self.topic], timeout_ms=30_000))
        finally:
            self.client.close()

    def test_roundtrip(self):
        produced = self.client.Produce(kafka_pb.ProduceRequest(
            topic=self.topic,
            partition=0,
            records=[kafka_pb.Record(value=v) for v in (b"one", b"two", b"three")],
            acks=kafka_pb.Acks.ACKS_ALL))
        self.assertEqual(produced.error_code, 0, produced)

        values = []
        stream = self.client.Consume(kafka_pb.ConsumeRequest(
            topic=self.topic, partition=0, offset=-2,
            max_records=10, max_wait_ms=2_000))
        try:
            for chunk in stream:
                self.assertEqual(chunk.error_code, 0, chunk)
                for rec in chunk.records:
                    values.append(rec.value)
                if len(values) >= 3:
                    break
        finally:
            stream.close()
        self.assertEqual(values, [b"one", b"two", b"three"])

        offsets = self.client.ListOffsets(kafka_pb.ListOffsetsRequest(
            topic=self.topic, partition=0, timestamp=-1))
        self.assertEqual(offsets.error_code, 0, offsets)
        self.assertEqual(offsets.offset, 3)


if __name__ == "__main__":
    unittest.main()
