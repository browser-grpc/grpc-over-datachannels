# Separate kafka-grpc packages

Each `kafka-<lang>` tree here is a standalone package of the
generated `grpcdc.kafka.v1` stubs for one ecosystem, depending
on that ecosystem's `grpc-dc` package at the same version:

| Tree | Package | Depends on |
|---|---|---|
| kafka-js | npm `kafka-grpc` / GitHub `@browser-grpc/kafka-grpc` | `grpc-dc` / `@browser-grpc/grpc-dc` |
| kafka-python | PyPI `kafka-grpc` | `grpc-dc` |
| kafka-ruby | RubyGems/GitHub `kafka-grpc` | `grpc-dc` |
| kafka-csharp | NuGet/GitHub `KafkaGrpc` | `GrpcDc` |
| kafka-java | Maven `io.github.browser-grpc:kafka-grpc` | `io.github.browser-grpc:grpc-dc` |
| kafka-rust | crates.io `kafka-grpc` | `grpc-dc` |
| kafka-go | module `github.com/browser-grpc/grpc-over-datachannels/kafka` | `.../go` |
| kafka-dart | pub.dev `kafka_grpc` | pub.dev `grpc_dc` |

Kotlin, Scala, PHP, Lua, Swift, Zig, C and C++ carry the
same two generated files inside their grpc-dc trees (those
ecosystems have no separate package split here). Publishing is
driven by scripts/release-push.sh; see GITHUB-PACKAGES.md.
