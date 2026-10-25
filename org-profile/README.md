# browser-grpc

<p align="center"><img src="https://browser-grpc.github.io/grpc-over-datachannels/badger/honey-badger-256.png" width="160" alt="Honey badger mascot — browser-grpc"></p>

**gRPC in the browser, over WebRTC DataChannels.** Dependency-free gRPC clients and servers for 16 languages that run in browser tabs (native RTCDataChannel, plus Wasm clients) and natively — no grpc-web proxy, no external gRPC runtime.

Start in 60 seconds, no toolchain install:

    git clone https://github.com/browser-grpc/grpc-over-datachannels
    cd grpc-over-datachannels
    docker build -f docker/go.Dockerfile -t grpc-dc-go .
    docker run --rm grpc-dc-go

Or generate stubs for your own schema in the browser:
https://browser-grpc.github.io/grpc-over-datachannels/app/#schema=echo&lang=go
