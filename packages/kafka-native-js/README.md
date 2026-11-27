# kafka-native (Node)

In-process Kafka client for Node over the shared Rust `libkafka_native` — direct Kafka protocol, no gRPC hop, no proxy. Generated `kafka_pb` messages are bundled; the native library + N-API addon ship as per-platform prebuilds (linux-x64, linux-arm64, darwin-arm64) under `prebuilds/`. Other platforms: build the addon from `kafka_native_addon.c` against a `libkafka_native` from the kafka-native repo and set `GRPC_DC_KAFKA_NATIVE_ADDON`.

Install: `npm install @browser-grpc/kafka-native`. Native only — browsers use `@browser-grpc/kafka-grpc` through kafka-proxy.
