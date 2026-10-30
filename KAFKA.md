# Kafka over gRPC

`proto/kafka.proto` (`grpcdc.kafka.v1.Kafka`) exposes a Kafka
cluster through the generated gRPC clients of every supported
language, browser and native. A single Rust proxy terminates
the generated service and speaks the Kafka binary protocol to
Apache Kafka (KRaft) or Redpanda, negotiating API versions per
connection.

## Run the proxy

```sh
docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .
docker run --rm kafka-proxy --tcp 0.0.0.0:50201 --broker kafka:9092
```

Or from the published image:

```sh
docker run --rm ghcr.io/browser-grpc/kafka-proxy:latest \
  --tcp 0.0.0.0:50201 --broker kafka:9092
```

Modes: `--stdio` (length-prefixed framing on stdin/stdout),
`--tcp ADDR` (the same framing over TCP, for any generated
client's sidecar transport), and `--webrtc-direct ADDR`
(gRPC over a WebRTC DataChannel).

Broker security: `--sasl-plain USER PASS`,
`--sasl-scram-sha-256 USER PASS`, or
`--sasl-scram-sha-512 USER PASS`; TLS via `--tls-ca-cert PEM`
or `--tls-insecure-skip-verify` (the image is built with TLS
support enabled).

## Service surface

- `Metadata`, `ListOffsets`, `CreateTopics`, `DeleteTopics`.
- `Produce` / `Consume` (server-streaming): per-partition
  ordering, offset resume, null-vs-empty record keys,
  `read_committed`, gzip/snappy/LZ4/zstd compression.
- Producer sessions: idempotent produce and transactions
  (commit/abort, transactional consume-produce).
- Consumer groups: range/roundrobin assignment, static
  membership with fencing, committed-offset resume,
  out-of-range auto-reset, and transparent reconnect after
  a broker restart.
- Multi-broker clusters route produce/fetch to the partition
  leader discovered from metadata.
