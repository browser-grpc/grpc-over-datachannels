# Kafka over gRPC proxy — generated. DO NOT EDIT.
#   docker build -f docker/kafka-proxy.Dockerfile -t kafka-proxy .
#   docker run --rm kafka-proxy --tcp 0.0.0.0:50201 --broker kafka:9092
FROM rust:1-bookworm AS build
WORKDIR /src
COPY rust ./rust
COPY webrtc/rust ./webrtc/rust
COPY proto ./proto
RUN cd rust && cargo build --release --locked --features kafka-tls,webrtc --example kafka_proxy
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/rust/target/release/examples/kafka_proxy /usr/local/bin/kafka_proxy
ENTRYPOINT ["kafka_proxy"]
CMD ["--help"]
