# grpc-dc (Lua)

gRPC over WebRTC DataChannels — a generated, dependency-free
Lua runtime (Lua 5.4, stdlib only): clients and servers
speaking the gRPC wire protocol over a WebRTC DataChannel.

Install: `luarocks install grpc-dc`, then
`require("grpcdc.channel")` etc. Kafka stubs ship separately
in the `kafka-grpc` rock, which depends on this one.
