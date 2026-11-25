"""Kafka Streams over gRPC end-to-end (Python interpreter
of the generated scenarios in kafka_streams_scenarios_generated.py,
which the streams scenario spec stamps for every
language; the JS suite interprets the same table).

Env-gated: set KAFKA_E2E_PROXY_ADDR=host:port of a running
kafka_proxy (see scripts/kafka-e2e.sh / `make test-kafka`).
Skipped otherwise.
"""

import os
import sys
import time
import unittest
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import grpcdc
from grpcdc.kafka_grpc_dc import KafkaClient
from grpcdc.kafka_streams_grpc_dc import KafkaStreamsClient
from grpcdc.kafka_pb import (
    ConsumeRequest,
    CreateTopicsRequest,
    DeleteTopicsRequest,
    NewTopic,
    ProduceRequest,
    Record,
)
from grpcdc.kafka_streams_pb import (
    CreateTopologyRequest,
    DeleteTopologyRequest,
    GetStoreValueRequest,
    Operator,
    Step,
    Topology,
)

sys.path.insert(0, os.path.dirname(__file__))
from kafka_streams_scenarios_generated import KAFKA_STREAMS_SCENARIOS

PROXY_ADDR = os.environ.get("KAFKA_E2E_PROXY_ADDR", "")


def _clients():
    host, _, port = PROXY_ADDR.rpartition(":")
    channel = grpcdc.Channel(grpcdc.SidecarTransport.connect(host, int(port)))
    return KafkaClient(channel), KafkaStreamsClient(channel)


@unittest.skipUnless(PROXY_ADDR, "KAFKA_E2E_PROXY_ADDR not set")
class TestKafkaStreamsScenarios(unittest.TestCase):
    def _run_scenario(self, scenario):
        kafka, streams = _clients()
        suffix = uuid.uuid4().hex[:12]
        source = f"py-streams-in-{suffix}"
        sink = f"py-streams-out-{suffix}"
        name = f"py-{scenario['name']}-{suffix}"
        try:
            for topic in (source, sink):
                created = kafka.CreateTopics(
                    CreateTopicsRequest(
                        topics=[NewTopic(name=topic, num_partitions=1, replication_factor=1)],
                        timeout_ms=15000,
                    )
                )
                self.assertEqual([r.error_code for r in created.results], [0])
            steps = [
                Step(
                    operator=getattr(Operator, op),
                    param=param,
                    aggregator=agg,
                )
                for (op, param, agg) in scenario["chain"]
            ]
            info = streams.CreateTopology(
                CreateTopologyRequest(
                    topology=Topology(
                        name=name, source_topic=source, sink_topic=sink, steps=steps
                    )
                )
            )
            self.assertEqual(info.state, "RUNNING")
            for line in scenario["lines"]:
                resp = kafka.Produce(
                    ProduceRequest(
                        topic=source,
                        partition=0,
                        records=[Record(value=line.encode())],
                    )
                )
                self.assertEqual(resp.error_code, 0)
            for key, want in scenario["store"].items():
                got = None
                for _ in range(80):
                    got = streams.GetStoreValue(
                        GetStoreValueRequest(topology=name, key=key)
                    )
                    if got.found and got.value == want:
                        break
                    time.sleep(0.25)
                self.assertTrue(got.found, f"store key {key} never appeared")
                self.assertEqual(got.value, want)
            # Final sink records per key.
            final = {}
            stream = kafka.Consume(
                ConsumeRequest(topic=sink, partition=0, offset=0, max_records=200)
            )
            deadline = time.time() + 20
            try:
                for chunk in stream:
                    self.assertEqual(chunk.error_code, 0)
                    for r in chunk.records:
                        final[r.key.decode()] = r.value.decode()
                    if len(final) >= len(scenario["sink"]):
                        break
                    if time.time() > deadline:
                        break
            finally:
                stream.close()
            self.assertEqual(final, scenario["sink"])
        finally:
            try:
                streams.DeleteTopology(DeleteTopologyRequest(name=name))
                kafka.DeleteTopics(
                    DeleteTopicsRequest(topics=[source, sink])
                )
            except Exception:
                pass


def _make_test(scenario):
    def test(self):
        self._run_scenario(scenario)

    return test


for _scenario in KAFKA_STREAMS_SCENARIOS:
    setattr(
        TestKafkaStreamsScenarios,
        "test_scenario_" + _scenario["name"].replace("-", "_"),
        _make_test(_scenario),
    )


if __name__ == "__main__":
    unittest.main()
