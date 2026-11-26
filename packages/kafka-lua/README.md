# kafka-grpc (Lua)

Generated `grpcdc.kafka.v1` clients for Lua (produce/consume/
groups/topics) over the `grpc-dc` runtime. Install:
`luarocks install kafka-grpc`, then
`require("kafka_grpc_dc")`.

What this is: generated gRPC client stubs — not the Kafka
protocol implementation. Connect them to a broker via
kafka-proxy, or use kafka-native for direct in-process
Kafka access. See KAFKA.md in the main repo.
