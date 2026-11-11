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


    def test_admin_describe_configs_and_list_groups(self):
        configs = self.client.DescribeConfigs(kafka_pb.DescribeConfigsRequest(
            resource_type=kafka_pb.ConfigResourceType.CONFIG_RESOURCE_TOPIC,
            resource_name=self.topic,
            config_keys=["max.message.bytes"]))
        self.assertEqual(configs.error_code, 0, configs)
        self.assertTrue(
            any(v.name == "max.message.bytes" for v in configs.values),
            configs)
        groups = self.client.ListGroups(kafka_pb.ListGroupsRequest())
        self.assertEqual(groups.error_code, 0, groups)


SASL_BROKER = os.environ.get("KAFKA_E2E_SASL_BROKER")
SASL_USER = os.environ.get("KAFKA_E2E_SASL_USER", "")
SASL_PASS = os.environ.get("KAFKA_E2E_SASL_PASS", "")
TLS_BROKER = os.environ.get("KAFKA_E2E_TLS_BROKER")
TLS_CA = os.environ.get("KAFKA_E2E_TLS_CA")


PROXY = os.environ.get("KAFKA_E2E_PROXY_ADDR")


@unittest.skipUnless(BROKER and LIB and PROXY, "differential env unset")
class TestKafkaDifferential(unittest.TestCase):
    """Same scenario through both form factors against the
    same broker: proxy-produced records must be identical
    when consumed natively, and vice versa."""

    def setUp(self):
        from grpcdc import Channel, SidecarTransport
        from grpcdc.kafka_grpc_dc import KafkaClient
        host, _, port = PROXY.rpartition(":")
        self.proxy = KafkaClient(Channel(SidecarTransport.connect(host, int(port))))
        self.native = NativeKafkaClient(BROKER)
        self.topic = unique("grpc-dc-diff")
        created = self.native.CreateTopics(kafka_pb.CreateTopicsRequest(
            topics=[kafka_pb.NewTopic(
                name=self.topic, num_partitions=1, replication_factor=1)],
            timeout_ms=30_000))
        self.assertEqual(created.results[0].error_code, 0, created)
        deadline = time.time() + 30
        while time.time() < deadline:
            meta = self.native.Metadata(kafka_pb.MetadataRequest(topics=[self.topic]))
            topics = [t for t in meta.topics if t.name == self.topic]
            if topics and topics[0].partitions:
                break
            time.sleep(0.2)
        else:
            self.fail("topic never became visible")

    def tearDown(self):
        try:
            self.native.DeleteTopics(kafka_pb.DeleteTopicsRequest(
                topics=[self.topic], timeout_ms=30_000))
        finally:
            self.native.close()

    def _consume_native(self, want, offset=-2):
        values = []
        stream = self.native.Consume(kafka_pb.ConsumeRequest(
            topic=self.topic, partition=0, offset=offset,
            max_records=10, max_wait_ms=2_000))
        try:
            for chunk in stream:
                for rec in chunk.records:
                    values.append(rec.value)
                if len(values) >= want:
                    break
        finally:
            stream.close()
        return values

    def test_proxy_produce_native_consume_and_reverse(self):
        produced = self.proxy.Produce(kafka_pb.ProduceRequest(
            topic=self.topic, partition=0,
            records=[kafka_pb.Record(value=v) for v in (b"p1", b"p2")],
            acks=kafka_pb.Acks.ACKS_ALL))
        self.assertEqual(produced.error_code, 0, produced)
        self.assertEqual(self._consume_native(2), [b"p1", b"p2"])

        produced = self.native.Produce(kafka_pb.ProduceRequest(
            topic=self.topic, partition=0,
            records=[kafka_pb.Record(value=b"n1")],
            acks=kafka_pb.Acks.ACKS_ALL))
        self.assertEqual(produced.error_code, 0, produced)

        values = []
        stream = self.proxy.Consume(kafka_pb.ConsumeRequest(
            topic=self.topic, partition=0, offset=2,
            max_records=10, max_wait_ms=2_000))
        for chunk in stream:
            for rec in chunk.records:
                values.append(rec.value)
            if values:
                break
        self.assertEqual(values, [b"n1"])

    def _consume_proxy(self, offset, want):
        values = []
        stream = self.proxy.Consume(kafka_pb.ConsumeRequest(
            topic=self.topic, partition=0, offset=offset,
            max_records=10, max_wait_ms=2_000))
        for chunk in stream:
            for rec in chunk.records:
                values.append(rec.value)
            if len(values) >= want:
                break
        return values

    def test_differential_compression_codecs(self):
        # Every codec both directions: bytes written through
        # one form factor must read back identically through
        # the other (the codec implementations are shared, so
        # this pins wire compatibility, not self-agreement).
        offset = 0
        for codec in (
            kafka_pb.Compression.COMPRESSION_GZIP,
            kafka_pb.Compression.COMPRESSION_SNAPPY,
            kafka_pb.Compression.COMPRESSION_LZ4,
            kafka_pb.Compression.COMPRESSION_ZSTD,
        ):
            payload = [f"c{codec}-{i}".encode() for i in range(3)]
            produced = self.proxy.Produce(kafka_pb.ProduceRequest(
                topic=self.topic, partition=0,
                records=[kafka_pb.Record(value=v) for v in payload],
                acks=kafka_pb.Acks.ACKS_ALL, compression=codec))
            self.assertEqual(produced.error_code, 0, produced)
            self.assertEqual(self._consume_native(3, offset), payload)
            offset += 3

            produced = self.native.Produce(kafka_pb.ProduceRequest(
                topic=self.topic, partition=0,
                records=[kafka_pb.Record(value=v) for v in payload],
                acks=kafka_pb.Acks.ACKS_ALL, compression=codec))
            self.assertEqual(produced.error_code, 0, produced)
            self.assertEqual(self._consume_proxy(offset, 3), payload)
            offset += 3

    def test_differential_transactional_read_committed(self):
        # Transactional produce through one form factor,
        # read_committed consume through the other: committed
        # records visible, aborted ones invisible.
        def txn(self_client, label, commit):
            opened = self_client.OpenProducer(
                kafka_pb.OpenProducerRequest(
                    transactional_id=unique(f"grpc-dc-diff-txn-{label}"),
                    transaction_timeout_ms=60_000))
            self.assertEqual(opened.error_code, 0, opened)
            produced = self_client.Produce(kafka_pb.ProduceRequest(
                topic=self.topic, partition=0,
                records=[kafka_pb.Record(value=label.encode())],
                acks=kafka_pb.Acks.ACKS_ALL,
                session_id=opened.session_id))
            self.assertEqual(produced.error_code, 0, produced)
            ended = self_client.EndTransaction(
                kafka_pb.EndTransactionRequest(
                    session_id=opened.session_id, commit=commit))
            self.assertEqual(ended.error_code, 0, ended)

        def consume_committed(client, want, timeout_s=20):
            values = []
            stream = client.Consume(kafka_pb.ConsumeRequest(
                topic=self.topic, partition=0, offset=-2,
                max_records=10, max_wait_ms=1_000,
                read_committed=True))
            deadline = time.time() + timeout_s
            try:
                for chunk in stream:
                    for rec in chunk.records:
                        values.append(rec.value)
                    if len(values) >= want or time.time() > deadline:
                        break
            finally:
                close = getattr(stream, "close", None)
                if close:
                    close()
            return values

        txn(self.proxy, "tx-proxy-commit", True)
        txn(self.proxy, "tx-proxy-abort", False)
        self.assertEqual(
            consume_committed(self.native, 1), [b"tx-proxy-commit"])

        txn(self.native, "tx-native-commit", True)
        txn(self.native, "tx-native-abort", False)
        self.assertEqual(
            consume_committed(self.proxy, 2),
            [b"tx-proxy-commit", b"tx-native-commit"])

    def test_differential_group_commit_parity(self):
        # Group state written through one form factor must be
        # visible through the other: native subscribes and
        # commits, proxy reads the committed offset back.
        group = unique("grpc-dc-diff-group")
        produced = self.proxy.Produce(kafka_pb.ProduceRequest(
            topic=self.topic, partition=0,
            records=[kafka_pb.Record(value=v) for v in (b"g1", b"g2", b"g3")],
            acks=kafka_pb.Acks.ACKS_ALL))
        self.assertEqual(produced.error_code, 0, produced)

        values = []
        stream = self.native.Subscribe(kafka_pb.GroupSubscribeRequest(
            group_id=group, topics=[self.topic],
            session_timeout_ms=30_000, max_poll_records=10,
            auto_offset_reset="earliest"))
        try:
            for chunk in stream:
                self.assertIsNone(chunk.group_error, chunk)
                if chunk.batch:
                    for rec in chunk.batch.records:
                        values.append(rec.value)
                if len(values) >= 3:
                    break
            self.assertEqual(values, [b"g1", b"g2", b"g3"])

            committed = self.native.CommitOffset(
                kafka_pb.CommitOffsetRequest(
                    group_id=group, topic=self.topic, partition=0,
                    committed_offset=2))
            self.assertEqual(committed.error_code, 0, committed)
        finally:
            stream.close()

        fetched = self.proxy.FetchOffset(kafka_pb.FetchOffsetRequest(
            group_id=group, topic=self.topic, partition=0))
        self.assertEqual(fetched.error_code, 0, fetched)
        self.assertEqual(fetched.committed_offset, 2, fetched)


@unittest.skipUnless(LIB and SASL_BROKER, "SASL native env unset")
class TestKafkaNativeSasl(unittest.TestCase):
    def test_sasl_mechanisms(self):
        for mech in ("PLAIN", "SCRAM-SHA-512"):
            client = NativeKafkaClient(
                SASL_BROKER, sasl_mechanism=mech,
                username=SASL_USER, password=SASL_PASS)
            try:
                meta = client.Metadata(kafka_pb.MetadataRequest(topics=[]))
                self.assertTrue(meta.brokers, mech)
            finally:
                client.close()

    def test_sasl_wrong_password_rejected(self):
        from grpcdc.kafka_native import NativeKafkaError
        client = NativeKafkaClient(
            SASL_BROKER, sasl_mechanism="PLAIN",
            username=SASL_USER, password="wrong-" + SASL_PASS)
        try:
            with self.assertRaises(NativeKafkaError):
                client.Metadata(kafka_pb.MetadataRequest(topics=[]))
        finally:
            client.close()


@unittest.skipUnless(LIB and TLS_BROKER and TLS_CA, "TLS native env unset")
class TestKafkaNativeTls(unittest.TestCase):
    def test_tls_metadata(self):
        client = NativeKafkaClient(TLS_BROKER, tls_ca_cert=TLS_CA)
        try:
            meta = client.Metadata(kafka_pb.MetadataRequest(topics=[]))
            self.assertTrue(meta.brokers)
        finally:
            client.close()


@unittest.skipUnless(LIB, "GRPC_DC_KAFKA_NATIVE_LIB unset")
class TestKafkaNativeErrors(unittest.TestCase):
    def test_missing_library_raises(self):
        from grpcdc.kafka_native import NativeKafkaError
        with self.assertRaises(NativeKafkaError):
            NativeKafkaClient("127.0.0.1:1", lib="/nonexistent/libkafka_native.so")

    def test_unreachable_broker_call_raises(self):
        from grpcdc.kafka_native import NativeKafkaError
        client = NativeKafkaClient("127.0.0.1:1")
        try:
            with self.assertRaises(NativeKafkaError):
                client.Metadata(kafka_pb.MetadataRequest(topics=["nope"]))
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
