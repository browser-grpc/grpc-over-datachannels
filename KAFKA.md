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

Three form factors, one wire implementation
(`crates/kafka-native`):

- `kafka-grpc` — the generated client stubs above, over gRPC
  transports. Browser OK; needs the proxy to reach a broker.
- `kafka-native` — the same Kafka protocol client as an
  in-process library (`crates/kafka-native`): Rust crate, C
  ABI (`libkafka_native`, `include/kafka_native.h`), and
  per-language FFI wrappers such as Python's
  `grpcdc.kafka_native.NativeKafkaClient`. Native apps only;
  no proxy, no gRPC hop. Requests and responses are the same
  generated messages, so swapping the sidecar for the library
  changes only client construction. SASL (PLAIN/SCRAM) and
  TLS are supported through the `kafka_native_new_v2` config.
- `kafka-proxy` — the `kafka_proxy` sidecar, a thin host over
  the same crate (stdio / TCP / WebRTC-Direct listeners).

Native coverage (in the `make test-kafka` gate): Rust direct
`Broker` roundtrip + admin (configs, partitions, groups) and
in-process `KafkaService`; FFI error paths (unknown method,
malformed bytes, null handle, `last_error`), `Subscribe`
through the ABI, and `stream_free` mid-stream followed by a
successful call; a C caller compiled against
`include/kafka_native.h`; Python roundtrip, admin, and error
legs. Per-language wrappers over the C ABI are generated for
Python, Ruby, Dart, C#, Java (JNI shim), PHP (stdlib FFI),
and JavaScript (pure N-API addon, async promises, SASL/TLS
v2 config); Go wraps it via cgo behind the `kafka_native`
build tag; C++ and Swift consume the header directly. Every
wrapper has a live-broker gate leg.

## Broker and protocol scope

Differential coverage: identical suites run against Apache
Kafka and Redpanda in the gate (two independent broker
implementations), and a Python differential leg cross-checks
the proxy and native form factors record-for-record against
the same broker. Consumer groups speak the next-generation consumer protocol
(KIP-848, ConsumerGroupHeartbeat) whenever the coordinator
advertises it: server-side assignment, epoch fencing, and
ConsumerGroupDescribe for group admin, with OffsetCommit
negotiated to v9. Brokers that refuse it (UNSUPPORTED_VERSION
on the joining heartbeat, or no topic-id Metadata) fall back
to the classic group protocol (JoinGroup/SyncGroup/Heartbeat)
transparently — same `Subscribe` stream either way.
`GroupSubscribeRequest.group_protocol` pins one or the other
("" auto, "consumer", "classic"). Static membership works on
both: classic fences a duplicate instance at JoinGroup, while
under KIP-848 the broker rejects the duplicate join until the
owner leaves, so a duplicate static subscribe inside one
service supersedes the older member itself. Share groups
(KIP-932) are implemented as session-based RPCs
(`OpenShareGroup` / `SharePoll` / `ShareAck` /
`CloseShareGroup`), because acknowledgements must flow back
from the client — something a server-stream cannot carry.
Records are acquired with delivery counts; `ACCEPT` retires
them, `RELEASE` redelivers with the count incremented.
Share partitions take their start offset when first fetched,
so records produced before the first poll of a fresh share
partition are not delivered (verified against the reference
share consumer). Member ids are client-generated Kafka
Uuids, as the protocol requires. `DescribeShareGroups`
(ShareGroupDescribe, API 77) reports live members, epochs,
and assignments; share groups are managed by the group
coordinator (client FindCoordinator key type 2 is rejected
by the broker).

## Service surface

- `Metadata`, `ListOffsets` — cluster/topic metadata, offsets.
- `Produce`, `Consume` (server-streaming) — the roundtrip path;
  per-partition ordering and offset resume are plain offsets.
- `OpenProducer` / `CloseProducer` / `EndTransaction` — producer
  sessions held by the proxy: idempotent produce (per-partition
  sequences) and transactions (commit/abort) across unary calls.
- `Subscribe` (server-streaming) — consumer groups held by the
  proxy: KIP-848 heartbeats with server-side assignment where
  supported (classic JoinGroup/SyncGroup with range +
  roundrobin assignors otherwise), rejoin on rebalance and
  fencing errors, committed-offset resume. `CommitOffset` /
  `FetchOffset` for explicit offsets.
  Each group member owns its coordinator connection (a parked
  JoinGroup must not starve other members' heartbeats), and a
  member rejoining after a rebalance heartbeat rejoins with
  its existing member id instead of leaving first. Multi-
  member assignment, static membership (`group_instance_id`,
  instance-derived member ids, fencing of the previous member
  on duplicate-instance join) are covered by e2e tests.
- `CreateTopics` / `DeleteTopics` — topic admin.
- Admin operations (broker-verified against Apache Kafka):
  `DescribeConfigs` / `AlterConfigs` (topic, broker,
  broker-logger, client-metrics and group resources; the
  incremental-alter wire form), `CreatePartitions`,
  `DeleteRecords`, `ListGroups` / `DescribeGroups`,
  `DeleteGroups`, `DeleteGroupOffsets` (Kafka only deletes
  committed offsets for an empty group), `DescribeAcls` /
  `CreateAcls` / `DeleteAcls` (a broker with no authorizer
  configured answers `SECURITY_DISABLED`), and
  `ListTransactions` / `DescribeTransactions`. Cancelling a
  `Subscribe` stream makes the proxy leave the group, so the
  member promptly disappears from `DescribeGroups`; the async
  Python and JS suites assert that path end to end.
- Connection safety: a broker request dropped mid-flight
  (cancelled stream, timeout) marks its pooled connection
  poisoned; the next request reconnects first instead of
  reading the stale response. `ListGroups` and
  `DescribeGroups` negotiate down to the broker's max version
  (Redpanda offers v4/v5 where Apache Kafka offers v5/v6).

Record keys distinguish null from empty: `Record.null_key`
produces a Kafka null key, and `FetchedRecord.key_null`
reports one; an empty key without the flag stays an empty
key. `Consume` long-polls at the high watermark (no chunk
until a record lands) and an out-of-range offset returns the
broker error (OFFSET_OUT_OF_RANGE) as the first chunk's
`error_code`; inside a consumer group the same condition
applies the `auto_offset_reset` policy instead of ending the
subscription. Broker connections are re-established
transparently after a transport failure, so a broker restart
does not permanently break the proxy: committed offsets and
group membership resume on the next calls (proven by a
dedicated restart leg in `scripts/kafka-e2e.sh` that bounces
Kafka between two consume phases). A proxy restart is also
covered: `kafka_proxy_group_proxy_restart_resume` replaces
the whole service instance mid-group and asserts the new
instance resumes exactly at the committed offset.

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

## Stream processing (Kafka Streams over gRPC)

The proxy also serves `grpcdc.kafka.streams.v1.KafkaStreams`
(`proto/kafka_streams.proto`, stubs generated for every
language by `make kafka-stubs`): the Kafka Streams model as
a gRPC interface, hosted by the proxy. Clients create a
declarative topology; the proxy runs it against the broker
(per-topology task: fetch source partitions, transform,
produce to the sink, commit offsets under the topology's
consumer group `application_id`, default `streams-<name>`)
and answers interactive queries (`GetStoreValue`) from its
state stores. Topologies are chains of steps
(`Topology.steps`, parameterized; the legacy `operators`
list still works for the word-count chain): stateless
`TOKENIZE_WORDS`, `MAP_VALUES` (upper/lower/trim/reverse),
`FILTER` (prefix/contains/key_equals/value_gt/value_lt),
`SELECT_KEY`, the `GROUP_BY_KEY` marker, and the stateful
`COUNT`, `AGGREGATE` (COUNT/SUM/MIN/MAX over int64 values),
and `REDUCE` (sum/min/max fold), plus `WINDOW_TUMBLING` /
`WINDOW_HOPPING` (window_size_ms / window_advance_ms /
grace_ms on the step) which make following stateful steps
aggregate per (key, window) on record timestamps, dropping
records whose window closed more than grace_ms behind
stream time; windowed results carry `window-start` /
`window-end` record headers and are queried with
`FetchWindow`, while `GetStoreValue` serves unwindowed
stores. `WINDOW_SESSION` (gap_ms) merges per-key sessions
within the gap, transferring aggregates across merges;
`WINDOW_SLIDING` anchors windows at record timestamps and
recomputes each window from the key's record history.
Both must be followed by a stateful step, whose combiner
they adopt. A `COGROUP` step (with
`Topology.cogroup_sources`) folds keyed decimal values
from additional topics into the same store (SUM) as they
arrive. `JOIN_GLOBAL_TABLE`
states the full-materialization guarantee in the API.
A `PROCESS` step routes each record through a
client-hosted `StreamsProcessor` service
(`proto/kafka_streams_processor.proto`, generated stubs;
step param `tcp://host:port`): the processor returns zero
or more replacement records and may read/write the
topology store through the proxy's `ProcessorContext`
service, while offsets, assignment, and transactions stay
with the proxy. Stateful steps require
`GROUP_BY_KEY` before them; anything unsupported is
rejected at `CreateTopology` time rather than silently
mis-executed. Each topology task joins its `application_id`
consumer group (classic JoinGroup/SyncGroup with the range
assignor; heartbeats, rejoin on fencing/rebalance, leave on
delete), so instances sharing an application id split the
source partitions — `TopologyInfo.assigned_partitions` and
`generation_id` report the live assignment — and offset
commits carry the member's generation.
`processing_guarantee: EXACTLY_ONCE` runs each fetch batch
in a Kafka transaction (transactional.id = application_id):
sink records, the source offset (AddOffsetsToTxn +
TxnOffsetCommit), and commit markers land atomically;
read_committed consumers see each emitted record once.
The default remains at-least-once. `JOIN_TABLE` joins the
stream against `Topology.table_topic`, which the task
materializes as a latest-value-per-key table (empty value
deletes): matching records emit
`value + separator + table value` (separator from the step
param, default `:`), records with no table entry drop, and
`GetStoreValue` also answers table lookups. Not yet
implemented: windowed joins, table-table joins,
standby replicas, persistent stores. Counts are
emitted as `(word, decimal-count)` records, sink-partitioned
by key hash. The store is in memory: a recreated topology restores it by
replaying the already-committed source range (no sink
emissions, no double counting) and then resumes live at the
committed offset; exactly-once transactional processing is
future work. The
JS suite `js/test/kafka_streams.test.js` drives the whole
path (create, produce sentences, sink counts, store queries,
unsupported-chain rejection) against both brokers in
`make test-kafka`.

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
