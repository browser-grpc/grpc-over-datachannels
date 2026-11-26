# kafka-grpc (Ruby)

Kafka over gRPC — generated grpcdc.kafka.v1 clients (produce/consume/groups/topics) speaking gRPC over WebRTC DataChannels, via the grpc-dc runtime (Ruby).

What this is: generated gRPC **client stubs** for the `grpcdc.kafka.v1` service — not the Kafka protocol implementation. To connect these clients to a broker, run kafka-proxy; for direct in-process Kafka access with no gRPC, use kafka-native. Decision guide: https://github.com/browser-grpc/grpc-over-datachannels/blob/main/KAFKA.md ("Which Kafka package do I need?").

Install: `gem install kafka-grpc` (depends on `grpc-dc`).
