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
    ConsumeRequest,
    CreateTopicsRequest,
    DeleteTopicsRequest,
    DescribeConfigsRequest,
    DescribeGroupsRequest,
    GroupSubscribeRequest,
    ListGroupsRequest,
    ListOffsetsRequest,
    NewTopic,
    ProduceRequest,
    Record,
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


if __name__ == "__main__":
    unittest.main()
