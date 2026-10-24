# Browser examples: Echo in every Wasm language

Each language below runs its generated gRPC client in your
browser (Wasm facade over the JS wire runtime) against the
generated Echo server on the Node WebRTC stack.

Run them all with Docker (signaling included):

    docker compose --profile browser-examples up
    # open http://localhost:8080/ and pick a language

Or locally without Docker:

    node examples/browser/server.mjs
    # open http://localhost:8080/

On a phone or second machine, use the tunnel profile:

    docker compose --profile tunnel-browser up
    # open the printed https://*.trycloudflare.com URL

The pages are the same harnesses the Playwright BDD suites
drive; the server exchanges SDP over WebSocket, then the gRPC
calls run peer-to-peer over the `grpc` DataChannel.