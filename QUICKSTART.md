# Quickstart

Three paths, shortest first. Everything is dependency-free:
generated runtimes use only each language's standard library.

## 1. Your first RPC in the browser (2 minutes, no install)

Open the [live generator](https://browser-grpc.github.io/grpc-over-datachannels/app/)
and press **Run your first RPC**. The page generates the Echo
client from the bundled schema, serves it in-page over a
loopback DataChannel pair (the same transport a real
`RTCDataChannel` plugs into), and shows the calls plus the
~10 lines of JavaScript you would write:

```js
import { Channel, Server, memoryDataChannelPair } from "grpc-dc";
import { EchoClient, createEchoService } from "./echo_grpc_dc.js";
import { EchoRequest } from "./echo_pb.js";

const [a, b] = memoryDataChannelPair();
const server = new Server();
server.addService(createEchoService({ /* your handlers */ }));
server.serve(b);

const client = new EchoClient(new Channel(a));
const reply = await client.unary(new EchoRequest({ message: "hello" }));
console.log(reply.message); // echo: hello
```

In production the loopback pair is replaced by a real
`RTCDataChannel` from two `RTCPeerConnection`s (or a native
peer); `Channel` and the generated client do not change.
Install the runtime with `npm install grpc-dc` (or copy the
`js/` directory — it has no dependencies either way). The
package ships TypeScript declarations (`index.d.ts`), so the
runtime is typed in TS projects.

## 2. Browser client ↔ native server (5 minutes)

The runnable step-2 sample pairs a real browser client with
the native stack server (SDP exchanged as plain text — swap
in WebSocket/fetch signaling in your app):

    node browser-test/native_step2.mjs chromium

Expected: `step2 (chromium): browser gRPC client -> native stack server OK { unary: 'echo: hello', ticks: [ 0, 1, 2 ], echoed: [ 'x', 'y' ] }`. Chromium, Firefox, and WebKit all
work. For native-to-native and cross-language proofs, each
language image runs its full suite and the interop image
pairs clients and servers across languages:

No toolchain install; each image runs that language's full
test suite, and the interop image pairs clients and servers
across languages:

    git clone https://github.com/browser-grpc/grpc-over-datachannels
    cd grpc-over-datachannels
    docker build -f docker/go.Dockerfile -t grpc-dc-go .
    docker run --rm grpc-dc-go
    docker compose up   # interop proof + browser demo on :8080

Then open http://localhost:8080/app/#schema=echo&lang=js for
the generated JavaScript browser client.

## 3. Stubs for your own .proto

In the browser: paste your schema into the live generator,
tick your language, download the zip (stubs + runtime +
README, runs as-is). On the command line with protoc:

    ln -s "$PWD/docs/app/protoc-gen-grpc-dc.mjs" ~/bin/protoc-gen-grpc-dc-js
    protoc --plugin=protoc-gen-grpc-dc-js=$HOME/bin/protoc-gen-grpc-dc-js \
           --grpc-dc-js_out=out -I . your.proto

One wrapper per language ships in `bin/`. Per-language
details (first run, regenerate, API tour) are in each
language's `README.md` — e.g. [`js/README.md`](js/README.md).
