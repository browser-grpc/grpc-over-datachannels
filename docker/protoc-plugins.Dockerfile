# protoc + grpc-dc protoc plugins — generated. DO NOT EDIT.
#   docker build -f docker/protoc-plugins.Dockerfile -t protoc-plugins .
#   docker run --rm -v "$PWD":/work protoc-plugins -I. --grpc-dc-rust_out=gen echo.proto
FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler && rm -rf /var/lib/apt/lists/*
COPY bin /plugins/bin
COPY docs/app/protoc-gen-grpc-dc.mjs /plugins/docs/app/protoc-gen-grpc-dc.mjs
COPY docs/app/gen /plugins/docs/app/gen
ENV PATH="/plugins/bin:${PATH}"
WORKDIR /work
ENTRYPOINT ["protoc"]
CMD ["--help"]
