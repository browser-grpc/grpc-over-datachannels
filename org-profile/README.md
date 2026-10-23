# browser-grpc

gRPC over WebRTC DataChannels for 16 languages: dependency-free generated runtimes, a
reimplemented WebRTC stack, and native + browser (Wasm)
clients and servers.

Start in 60 seconds, no toolchain install:

    git clone https://github.com/browser-grpc/grpc-over-datachannels
    cd grpc-over-datachannels
    docker build -f docker/go.Dockerfile -t grpc-dc-go .
    docker run --rm grpc-dc-go

Or generate stubs for your own schema in the browser:
https://browser-grpc.github.io/grpc-over-datachannels/app/#schema=echo&lang=go
