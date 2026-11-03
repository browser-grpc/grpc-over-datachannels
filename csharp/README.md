# C# — grpc-dc runtime

Start here if you are new to the project. The runtime in
this directory is generated and speaks the gRPC wire
protocol over WebRTC DataChannels (net8.0 dependency-free;
netstandard2.0 adds BCL compat packages).

## First run

```sh
    cd csharp && dotnet run --project tests -- TestEcho
```

## Use it in your project

`dotnet add package GrpcDc` (net8.0: zero dependencies; netstandard2.0 pulls three first-party BCL compat packages for async/JSON). The raw-TCP HTTP/2 transport is net8-only; the DataChannel core and generated stubs run everywhere.

### Unity (and .NET Framework 4.7.2+, Mono, Xamarin)

The netstandard2.0 build is the Unity target. Add `GrpcDc` with NuGetForUnity (or drop the `lib/netstandard2.0` DLLs plus `Microsoft.Bcl.AsyncInterfaces`, `System.Threading.Channels`, and `System.Text.Json` into `Assets/Plugins`). Implement `Grpcdc.ITransport` over your `RTCDataChannel` — `Send(byte[])` per message, `Recv()` blocking until the next message (throw `EndOfStreamException` on close), and `Close()` (explicit on netstandard; it has a default only on net8) — then serve or dial exactly like the Echo example in `examples/`. A maintained consumer doing this against the packed nupkg lives in the source repo under `csharp/tests-netstandard` and runs in CI under Mono.

## Regenerate stubs for your schema

From the repository root (one wrapper per language in `bin/`):

    protoc --plugin=protoc-gen-grpc-dc-csharp=$PWD/bin/protoc-gen-grpc-dc-csharp \
           --grpc-dc-csharp_out=out -I . your.proto

Or generate in the browser and download the zip:
https://browser-grpc.github.io/grpc-over-datachannels/app/

## Where things live

- Runtime: this directory (see its generated sources).
- Worked example: `examples/` (Echo in every method shape).
- Tests: `tests/` — the same BDD scenarios every language runs.

Full project quickstart: [`../QUICKSTART.md`](../QUICKSTART.md).
