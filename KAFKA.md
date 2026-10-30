# Kafka over gRPC

`proto/kafka.proto` (`grpcdc.kafka.v1.Kafka`) exposes a Kafka
cluster through the generated gRPC clients of every supported
language, browser and native. A single Rust proxy
(`rust/examples/kafka_proxy`) terminates the generated service
and speaks the Kafka binary protocol to Apache Kafka (latest,
KRaft) or Redpanda (latest), negotiating API versions per
connection (`ApiVersions`, with legacy-version fallbacks where
brokers cap versions, e.g. Redpanda's Produce v7).

```
generated client (any language)          kafka_proxy                broker
  Channel over                           (Rust, examples)      Apache Kafka
  DataChannel / TCP / stdio  ────────▶   generated Kafka  ───▶  or Redpanda
                                         service + Kafka
                                         binary protocol
```

## Service surface

- `Metadata`, `ListOffsets` — cluster/topic metadata, offsets.
- `Produce`, `Consume` (server-streaming) — the roundtrip path;
  per-partition ordering and offset resume are plain offsets.
- `OpenProducer` / `CloseProducer` / `EndTransaction` — producer
  sessions held by the proxy: idempotent produce (per-partition
  sequences) and transactions (commit/abort) across unary calls.
- `Subscribe` (server-streaming) — consumer groups held by the
  proxy: JoinGroup/SyncGroup with range + roundrobin assignors,
  heartbeats, rejoin on rebalance errors, committed-offset
  resume. `CommitOffset` / `FetchOffset` for explicit offsets.
  Each group member owns its coordinator connection (a parked
  JoinGroup must not starve other members' heartbeats), and a
  member rejoining after a rebalance heartbeat rejoins with
  its existing member id instead of leaving first. Multi-
  member assignment, static membership (`group_instance_id`,
  instance-derived member ids, fencing of the previous member
  on duplicate-instance join) are covered by e2e tests.
- `CreateTopics` / `DeleteTopics` — topic admin.

Record keys distinguish null from empty: `Record.null_key`
produces a Kafka null key, and `FetchedRecord.key_null`
reports one; an empty key without the flag stays an empty
key. `Consume` long-polls at the high watermark (no chunk
until a record lands) and an out-of-range offset returns the
broker error (OFFSET_OUT_OF_RANGE) as the first chunk's
`error_code`.

Compression: gzip, snappy, LZ4, and zstd (dependency-free
codecs in the proxy; zstd frames use raw blocks, and the
decoder also handles FSE/Huffman-compressed blocks from other
clients). SASL: PLAIN, SCRAM-SHA-256, SCRAM-SHA-512
(handshake runs before `ApiVersions`; some brokers reject
`ApiVersions` on a SASL listener first), verified against
both Apache Kafka and Redpanda fixtures. TLS to the broker
via rustls (`--features kafka-tls` on the proxy build;
`--tls-ca-cert PEM` or `--tls-insecure-skip-verify`).

Transactions support consume-produce: `CommitOffset` with a
producer `session_id` stages the offset, and `EndTransaction`
attaches it (`AddOffsetsToTxn` + `TxnOffsetCommit`) so records
and offsets commit or abort atomically. `read_committed` on
`Consume` / `GroupSubscribe` / `ListOffsets` maps to fetch
isolation level 1 with last-stable-offset and aborted-producer
filtering in the proxy; the proxy also appends COMMIT/ABORT
control batches for brokers that resolve transactions in the
coordinator without writing log markers.

Multi-broker clusters: produce, fetch and list-offsets route
to the partition leader discovered from metadata (bootstrap
fallback when the advertised leader is unreachable), proven
on a two-broker Apache Kafka cluster by
`kafka_proxy_multi_broker_leader_routing`.

## Running the proxy

```
cd rust
cargo run --example kafka_proxy -- --stdio --broker 127.0.0.1:19092
cargo run --example kafka_proxy -- --tcp 127.0.0.1:50201 --broker 127.0.0.1:19092
cargo run --features webrtc --example kafka_proxy -- \
    --webrtc-direct 127.0.0.1:4433 --broker 127.0.0.1:19092
cargo run --example kafka_proxy -- --tcp 127.0.0.1:50201 \
    --broker 127.0.0.1:19097 --sasl-scram-sha-256 USER PASS
cargo run --features kafka-tls --example kafka_proxy -- \
    --tcp 127.0.0.1:50201 --broker 127.0.0.1:19098 \
    --tls-ca-cert ca.crt
```

Modes:

- `--stdio`: one length-prefixed stdio DataChannel (tests,
  sidecars).
- `--tcp HOST:PORT`: length-prefixed TCP (u32 big-endian per
  message, the `direct_sidecar` framing). Every generated
  client's `SidecarTransport` connects here directly.
- `--webrtc-direct ADDR` (`--features webrtc`): real WebRTC
  DataChannels for browser and native clients. Front it with
  the shipped `proxy/grpc-dc-proxy.mjs --dc-dial <multiaddr>
  --http2 PORT` and stock gRPC clients reach the Kafka service
  over ordinary HTTP/2 over TCP — the same ingress composition
  as every other grpc-dc service.

SASL flags: `--sasl-plain USER PASS`,
`--sasl-scram-sha-256 USER PASS`, `--sasl-scram-sha-512 USER PASS`.
TLS flags (build with `--features kafka-tls`): `--tls-ca-cert PEM`
(verify against a CA file; the broker host or `--tls-server-name`
is the TLS server name) or `--tls-insecure-skip-verify`.

## End-to-end tests

Per-language suites (produce/consume roundtrip, per-partition
ordering, offset resume) live in each language's normal test
tree as `TestKafkaE2E` / `test_kafka_e2e` / `kafka.test.js` /
`TestKafka*`, env-gated on `KAFKA_E2E_PROXY_ADDR` so plain
per-language runs skip them. `make test-kafka`
(`scripts/kafka-e2e.sh`) starts both brokers and three SASL
proxies, then runs:

- the Rust in-process suite (roundtrip, compression,
  idempotence + transactions, transactional consume-produce
  with `read_committed`, consumer group) against the broker
  directly, and
- every language suite through a `--tcp` proxy, against both
  brokers, plus one suite per SASL mechanism against both
  Apache Kafka and Redpanda, per TLS mode (CA-verified,
  insecure-skip-verify) against Redpanda, and a two-broker
  Apache Kafka cluster leg proving partition-leader routing.

In CI the brokers come from `Dockerfile.ci` (Apache Kafka
4.3.1 tarball, Redpanda from its apt repo), started by the
script with single-node settings (transaction state log and
offsets topic at replication factor 1, `min.isr` 1). Locally,
already-listening brokers on the same ports are reused
(e.g. `apache/kafka:latest` / `redpandadata/redpanda:latest`
containers with host networking — host networking matters:
with a transactional producer, the broker dials its own
advertised listener to verify transaction membership).
