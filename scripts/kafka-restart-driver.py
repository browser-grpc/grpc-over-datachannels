"""Broker-restart leg driver for scripts/kafka-e2e.sh.

Phase 1 (before the bounce): create the topic, produce two
records, consume them through a consumer group, commit
offset 2.

Phase 2 (after the bounce): produce a third record (retrying
while the proxy re-establishes broker connections), then
resubscribe the same group and expect exactly the third
record -- committed-offset resume across a broker restart.

Env: KAFKA_E2E_PROXY_ADDR, KAFKA_RESTART_TOPIC,
KAFKA_RESTART_GROUP. Usage: kafka-restart-driver.py phase1|phase2
"""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

import grpcdc
from grpcdc.kafka_grpc_dc import KafkaClient
from grpcdc.kafka_pb import (
    CommitOffsetRequest,
    CreateTopicsRequest,
    FetchOffsetRequest,
    GroupSubscribeRequest,
    NewTopic,
    ProduceRequest,
    Record,
)

ADDR = os.environ["KAFKA_E2E_PROXY_ADDR"]
TOPIC = os.environ["KAFKA_RESTART_TOPIC"]
GROUP = os.environ["KAFKA_RESTART_GROUP"]


def client():
    host, _, port = ADDR.rpartition(":")
    channel = grpcdc.Channel(grpcdc.SidecarTransport.connect(host, int(port)))
    return KafkaClient(channel)


def produce(c, value):
    resp = c.Produce(
        ProduceRequest(
            topic=TOPIC,
            partition=0,
            records=[Record(key=b"k-" + value, value=value)],
        )
    )
    assert resp.error_code == 0, f"produce {value}: {resp}"
    return resp.base_offset


def collect_group(c, want, deadline_s=90):
    stream = c.Subscribe(
        GroupSubscribeRequest(
            group_id=GROUP,
            topics=[TOPIC],
            session_timeout_ms=30000,
            max_poll_records=10,
            auto_offset_reset="earliest",
        )
    )
    got = []
    deadline = time.time() + deadline_s
    try:
        for event in stream:
            if event.group_error is not None:
                raise AssertionError(f"group error: {event.group_error}")
            if event.batch is not None:
                got.extend(r.value for r in event.batch.records)
                if len(got) >= want:
                    break
            if time.time() > deadline:
                break
    finally:
        stream.close()
    return got


def phase1():
    c = client()
    resp = c.CreateTopics(
        CreateTopicsRequest(
            topics=[NewTopic(name=TOPIC, num_partitions=1, replication_factor=1)],
            timeout_ms=15000,
        )
    )
    assert [r.error_code for r in resp.results] == [0], resp
    assert produce(c, b"r-1") == 0
    assert produce(c, b"r-2") == 1
    got = collect_group(c, 2)
    assert got == [b"r-1", b"r-2"], got
    resp = c.CommitOffset(
        CommitOffsetRequest(group_id=GROUP, topic=TOPIC, partition=0, committed_offset=2)
    )
    assert resp.error_code == 0, resp
    fetched = c.FetchOffset(FetchOffsetRequest(group_id=GROUP, topic=TOPIC, partition=0))
    assert fetched.committed_offset == 2, fetched
    print("restart phase1 ok")


def phase2():
    c = client()
    # The proxy's pooled broker connections died with the
    # broker; produce may need a few attempts while they are
    # re-established.
    deadline = time.time() + 90
    offset = None
    while time.time() < deadline:
        try:
            offset = produce(c, b"r-3")
            break
        except Exception:
            time.sleep(2)
    assert offset == 2, f"r-3 landed at {offset}"
    got = collect_group(c, 1)
    assert got == [b"r-3"], f"resume after restart delivered {got}"
    print("restart phase2 ok")


if __name__ == "__main__":
    {"phase1": phase1, "phase2": phase2}[sys.argv[1]]()
