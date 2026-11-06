# grpc-dc (Ruby)

gRPC over WebRTC DataChannels — a generated, stdlib-only
Ruby runtime: clients and servers speaking the gRPC wire
protocol over a WebRTC DataChannel. No `grpc` gem (or any
other gem) underneath.

Install: `gem install grpc-dc`, then `require "grpcdc"`
(or `require "grpc_dc"`). Kafka stubs ship separately in
the `kafka-grpc` gem, which depends on this one.
