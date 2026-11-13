"""Kafka proxy end-to-end: generated Python client -> Rust
kafka_proxy (--tcp) -> Apache Kafka / Redpanda.

Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
Skipped otherwise, so the plain `make test-python` run stays
broker-free.
"""

import asyncio
import os
import sys
import time
import unittest
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import grpcdc
from grpcdc.kafka_grpc_dc import KafkaClient, KafkaClientAsync
from grpcdc.kafka_pb import (
    CloseShareGroupRequest,
    ConsumeRequest,
    CreateTopicsRequest,
    DeleteTopicsRequest,
    DescribeConfigsRequest,
    DescribeGroupsRequest,
    GroupSubscribeRequest,
    ListGroupsRequest,
    ListOffsetsRequest,
    NewTopic,
    OpenShareGroupRequest,
    ProduceRequest,
    Record,
    ShareAckEntry,
    ShareAckRequest,
    SharePollRequest,
)

PROXY_ADDR = os.environ.get("KAFKA_E2E_PROXY_ADDR", "")


def _client():
    host, _, port = PROXY_ADDR.rpartition(":")
    channel = grpcdc.Channel(grpcdc.SidecarTransport.connect(host, int(port)))
    return KafkaClient(channel)


def _async_client():
    host, _, port = PROXY_ADDR.rpartition(":")
    channel = grpcdc.AsyncChannel(grpcdc.SidecarTransport.connect(host, int(port)))
    return KafkaClientAsync(channel)


@unittest.skipUnless(PROXY_ADDR, "KAFKA_E2E_PROXY_ADDR not set")
class TestKafkaE2E(unittest.TestCase):
    def setUp(self):
        self.client = _client()
        self.topic = "py-kafka-e2e-" + uuid.uuid4().hex[:16]
        resp = self.client.CreateTopics(
            CreateTopicsRequest(
                topics=[NewTopic(name=self.topic, num_partitions=1, replication_factor=1)],
                timeout_ms=15000,
            )
        )
        self.assertEqual([r.error_code for r in resp.results], [0])
        # Wait until the partition is visible in metadata.
        deadline = time.time() + 15
        while time.time() < deadline:
            latest = self.client.ListOffsets(
                ListOffsetsRequest(topic=self.topic, partition=0, timestamp=-1)
            )
            if latest.error_code == 0:
                break
            time.sleep(0.25)

    def tearDown(self):
        try:
            self.client.DeleteTopics(DeleteTopicsRequest(topics=[self.topic]))
        except Exception:
            pass

    def _produce(self, values):
        offsets = []
        for value in values:
            resp = self.client.Produce(
                ProduceRequest(
                    topic=self.topic,
                    partition=0,
                    records=[Record(key=b"k-" + value, value=value)],
                )
            )
            self.assertEqual(resp.error_code, 0)
            offsets.append(resp.base_offset)
        return offsets

    def _consume(self, offset, count):
        stream = self.client.Consume(
            ConsumeRequest(topic=self.topic, partition=0, offset=offset, max_records=count)
        )
        got = []
        try:
            for chunk in stream:
                self.assertEqual(chunk.error_code, 0)
                got.extend(chunk.records)
                if len(got) >= count:
                    break
        finally:
            stream.close()
        return got

    def test_produce_consume_roundtrip(self):
        self.assertEqual(self._produce([b"v0", b"v1", b"v2"]), [0, 1, 2])
        latest = self.client.ListOffsets(
            ListOffsetsRequest(topic=self.topic, partition=0, timestamp=-1)
        )
        self.assertEqual((latest.offset, latest.error_code), (3, 0))
        got = self._consume(0, 3)
        self.assertEqual([r.value for r in got], [b"v0", b"v1", b"v2"])
        self.assertEqual([r.key for r in got], [b"k-v0", b"k-v1", b"k-v2"])

    def test_per_partition_ordering(self):
        values = [b"seq-%02d" % i for i in range(10)]
        self.assertEqual(self._produce(values), list(range(10)))
        got = self._consume(0, 10)
        self.assertEqual([r.value for r in got], values)

    def test_offset_resume(self):
        self._produce([b"a", b"b", b"c", b"d"])
        first = self._consume(0, 2)
        self.assertEqual([r.value for r in first], [b"a", b"b"])
        rest = self._consume(2, 2)
        self.assertEqual([r.value for r in rest], [b"c", b"d"])


@unittest.skipUnless(PROXY_ADDR, "KAFKA_E2E_PROXY_ADDR not set")
class TestKafkaAsyncE2E(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.client = _async_client()
        self.topic = "py-kafka-async-" + uuid.uuid4().hex[:16]
        resp = await self.client.CreateTopics(
            CreateTopicsRequest(
                topics=[NewTopic(name=self.topic, num_partitions=1, replication_factor=1)],
                timeout_ms=15000,
            )
        )
        self.assertEqual([r.error_code for r in resp.results], [0])
        deadline = time.time() + 15
        while time.time() < deadline:
            latest = await self.client.ListOffsets(
                ListOffsetsRequest(topic=self.topic, partition=0, timestamp=-1)
            )
            if latest.error_code == 0:
                break
            await asyncio.sleep(0.25)

    async def asyncTearDown(self):
        try:
            await self.client.DeleteTopics(DeleteTopicsRequest(topics=[self.topic]))
        except Exception:
            pass

    async def _produce(self, values):
        offsets = []
        for value in values:
            resp = await self.client.Produce(
                ProduceRequest(
                    topic=self.topic,
                    partition=0,
                    records=[Record(key=b"k-" + value, value=value)],
                )
            )
            self.assertEqual(resp.error_code, 0)
            offsets.append(resp.base_offset)
        return offsets

    async def test_async_roundtrip_and_admin(self):
        self.assertEqual(await self._produce([b"v0", b"v1", b"v2"]), [0, 1, 2])
        latest = await self.client.ListOffsets(
            ListOffsetsRequest(topic=self.topic, partition=0, timestamp=-1)
        )
        self.assertEqual((latest.offset, latest.error_code), (3, 0))
        stream = await self.client.Consume(
            ConsumeRequest(topic=self.topic, partition=0, offset=0, max_records=3)
        )
        got = []
        try:
            async for chunk in stream:
                self.assertEqual(chunk.error_code, 0)
                got.extend(chunk.records)
                if len(got) >= 3:
                    break
        finally:
            stream.cancel()
        self.assertEqual([r.value for r in got], [b"v0", b"v1", b"v2"])
        configs = await self.client.DescribeConfigs(
            DescribeConfigsRequest(
                resource_type=2,  # TOPIC
                resource_name=self.topic,
                config_keys=["max.message.bytes"],
            )
        )
        self.assertEqual(configs.error_code, 0)
        groups = await self.client.ListGroups(ListGroupsRequest())
        self.assertEqual(groups.error_code, 0)

    async def test_async_subscribe_cancel_leaves_group(self):
        await self._produce([b"x"])
        group = "py-kafka-async-group-" + uuid.uuid4().hex[:12]
        stream = await self.client.Subscribe(
            GroupSubscribeRequest(
                group_id=group,
                topics=[self.topic],
                session_timeout_ms=30000,
                max_poll_records=10,
                auto_offset_reset="earliest",
            )
        )
        saw_assignment = asyncio.Event()

        async def drain():
            async for resp in stream:
                if resp.assignment and resp.assignment.partitions:
                    saw_assignment.set()

        task = asyncio.create_task(drain())
        try:
            await asyncio.wait_for(saw_assignment.wait(), timeout=20)
        finally:
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            stream.cancel()
        # Cancelling the subscription must reach the proxy, which
        # leaves the group: the member disappears from describe.
        deadline = time.time() + 20
        while time.time() < deadline:
            described = await self.client.DescribeGroups(
                DescribeGroupsRequest(group_ids=[group])
            )
            if described.groups and not described.groups[0].members:
                break
            await asyncio.sleep(0.25)
        else:
            self.fail(f"member never left after cancel: {described}")
        # The channel is still usable after the cancellation.
        latest = await self.client.ListOffsets(
            ListOffsetsRequest(topic=self.topic, partition=0, timestamp=-1)
        )
        self.assertEqual(latest.error_code, 0)


@unittest.skipUnless(PROXY_ADDR, "KAFKA_E2E_PROXY_ADDR not set")
class TestKafkaShareE2E(unittest.TestCase):
    """KIP-932 share groups via the session RPCs: ACCEPT retires,
    RELEASE redelivers with delivery_count incremented. Brokers
    without share-group support (e.g. Redpanda) refuse the open
    and the test skips, mirroring the Rust share e2e."""

    def _poll(self, client, session, want, timeout_s=30):
        deadline = time.time() + timeout_s
        out = []
        while len(out) < want and time.time() < deadline:
            resp = client.SharePoll(
                SharePollRequest(session_id=session, max_records=10, max_wait_ms=500)
            )
            self.assertEqual(resp.error_code, 0)
            out.extend(resp.records)
            if not out:
                time.sleep(0.2)
        return out

    def _produce(self, client, topic, value):
        resp = client.Produce(
            ProduceRequest(topic=topic, partition=0, records=[Record(value=value)])
        )
        self.assertEqual(resp.error_code, 0)

    def test_share_accept_release_redelivery(self):
        client = _client()
        topic = "py-share-e2e-" + uuid.uuid4().hex[:16]
        group = "py-share-group-" + uuid.uuid4().hex[:16]
        resp = client.CreateTopics(
            CreateTopicsRequest(
                topics=[NewTopic(name=topic, num_partitions=1, replication_factor=1)],
                timeout_ms=15000,
            )
        )
        self.assertEqual([r.error_code for r in resp.results], [0])
        try:
            try:
                opened = client.OpenShareGroup(
                    OpenShareGroupRequest(group_id=group, topics=[topic])
                )
            except Exception as exc:  # broker without KIP-932
                self.skipTest(f"share group open raised: {exc}")
            if opened.error_code != 0:
                self.skipTest(
                    f"broker refused share group (error {opened.error_code})"
                )
            session = opened.session_id
            self.assertTrue(session)
            # Assignment settles asynchronously (bounded in the
            # service); it may still be empty here under load.
            # Delivery below is what proves it arrived.
            self.assertIsNotNone(opened.assignment)

            # A share partition's start offset is taken at its
            # first fetch; initialize it before producing.
            init = client.SharePoll(
                SharePollRequest(session_id=session, max_records=10, max_wait_ms=500)
            )
            self.assertEqual(init.error_code, 0)
            self.assertEqual(init.records, [])

            self._produce(client, topic, b"s1")
            self._produce(client, topic, b"s2")
            first = self._poll(client, session, 2)
            if not first and not opened.assignment.partitions:
                # The coordinator never assigned and nothing
                # delivers: this broker cannot initialize share
                # state (e.g. the gate's combined-mode SASL
                # fixture, whose share persister cannot
                # authenticate internally — the reference share
                # consumer stalls identically there). Delivery
                # failures WITH an assignment still fail below.
                self.skipTest("share assignment never delivered on this broker")
            self.assertEqual(len(first), 2, f"share delivery timed out: {first}")
            self.assertEqual([r.value for r in first], [b"s1", b"s2"])
            self.assertTrue(all(r.delivery_count == 1 for r in first))

            acked = client.ShareAck(
                ShareAckRequest(
                    session_id=session,
                    entries=[
                        ShareAckEntry(
                            topic=topic, partition=0, offset=r.offset, ack_type=1
                        )
                        for r in first
                    ],
                )
            )
            self.assertEqual(acked.error_code, 0)
            empty = client.SharePoll(
                SharePollRequest(session_id=session, max_records=10, max_wait_ms=500)
            )
            self.assertEqual(empty.error_code, 0)
            self.assertEqual(empty.records, [])

            self._produce(client, topic, b"s3")
            third = self._poll(client, session, 1)
            self.assertEqual(len(third), 1, "share delivery of s3 timed out")
            self.assertEqual(third[0].delivery_count, 1)
            released = client.ShareAck(
                ShareAckRequest(
                    session_id=session,
                    entries=[
                        ShareAckEntry(
                            topic=topic,
                            partition=0,
                            offset=third[0].offset,
                            ack_type=2,
                        )
                    ],
                )
            )
            self.assertEqual(released.error_code, 0)
            redelivered = self._poll(client, session, 1)
            self.assertEqual(len(redelivered), 1, "release redelivery timed out")
            self.assertEqual(redelivered[0].offset, third[0].offset)
            self.assertEqual(redelivered[0].delivery_count, 2)

            closed = client.CloseShareGroup(
                CloseShareGroupRequest(session_id=session)
            )
            self.assertEqual(closed.error_code, 0)
        finally:
            try:
                client.DeleteTopics(DeleteTopicsRequest(topics=[topic]))
            except Exception:
                pass


if __name__ == "__main__":
    unittest.main()
