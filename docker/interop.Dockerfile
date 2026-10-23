# Cross-language interop demo — generated. DO NOT EDIT.
#   docker build -f docker/interop.Dockerfile -t grpc-dc-interop .
#   docker run --rm grpc-dc-interop
FROM node:24-bookworm-slim AS node
FROM golang:1.24-bookworm
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY go ./go
COPY webrtc/go ./webrtc/go
COPY python ./python
COPY js ./js
CMD ["sh", "-c", "MATRIX_CLIENTS=python,go MATRIX_SERVERS=go,python node js/test/interop-matrix.mjs"]
