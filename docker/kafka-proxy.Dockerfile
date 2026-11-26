# Kafka over gRPC proxy — generated. DO NOT EDIT.
#   docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .
#   docker run --rm kafka-proxy --tcp 0.0.0.0:50201 --broker kafka:9092
FROM rust:1-bookworm AS build
WORKDIR /src
COPY rust ./rust
COPY crates/kafka-native ./crates/kafka-native
COPY crates/kafka-service ./crates/kafka-service
COPY apps/kafka-proxy ./apps/kafka-proxy
COPY webrtc/rust ./webrtc/rust
COPY proto ./proto
RUN cd apps/kafka-proxy && cargo build --release --locked --features kafka-tls,webrtc
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/apps/kafka-proxy/target/release/kafka_proxy /usr/local/bin/kafka_proxy
ENTRYPOINT ["kafka_proxy"]
CMD ["--help"]
