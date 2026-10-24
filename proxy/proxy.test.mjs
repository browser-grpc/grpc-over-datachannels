// Proxy spike test: a generated grpc-dc JS client, over a real
// WebRTC DataChannel (native Node stack on both peers), through
// grpc-dc-proxy, to a stock HTTP/2 gRPC backend (Node http2,
// hand-rolled Echo framing on the generated pb classes). Proves
// the bridge direction browser/native client -> proxy -> HTTP/2
// backend with no grpc-web and no backend changes.

import assert from "node:assert/strict";
import http2 from "node:http2";
import { readFile } from "node:fs/promises";
import { createServer } from "node:net";
import test from "node:test";

import { Channel } from "../js/index.js";
import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";
import { EchoClient } from "../js/examples/echo_grpc_dc.js";
import { Peer } from "../webrtc/js/peer.js";
import { LpmParser, lpm } from "../oracle/bridge.mjs";
import { startProxy } from "./grpc-dc-proxy.mjs";

function freePort() {
  const probe = createServer();
  return new Promise((resolve) => {
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

// Minimal stock-backend stand-in: HTTP/2 + gRPC LPM framing,
// canonical Echo semantics for Unary and ServerStream.
function startBackend() {
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    const path = headers[http2.constants.HTTP2_HEADER_PATH];
    const parser = new LpmParser("identity");
    let trailers = { "grpc-status": "0" };
    stream.respond(
      {
        [http2.constants.HTTP2_HEADER_STATUS]: 200,
        [http2.constants.HTTP2_HEADER_CONTENT_TYPE]: "application/grpc",
      },
      { waitForTrailers: true },
    );
    stream.on("wantTrailers", () => stream.sendTrailers(trailers));
    stream.on("data", (chunk) => {
      for (const payload of parser.push(chunk)) {
        const req = EchoRequest.decode(payload);
        if (req.message === "fail") {
          trailers = { "grpc-status": "3", "grpc-message": "asked to fail" };
          stream.end();
          return;
        }
        if (path.endsWith("/ServerStream")) {
          for (let i = 0; i < Math.max(0, req.count); i++) {
            stream.write(lpm(EchoResponse.encode(new EchoResponse({ message: req.message, index: i }))));
          }
          stream.end();
        } else {
          stream.write(lpm(EchoResponse.encode(new EchoResponse({ message: `echo: ${req.message}`, index: 0 }))));
          stream.end();
        }
      }
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () =>
      resolve({ server, port: server.address().port, close: () => new Promise((d) => server.close(d)) }),
    );
  });
}

test("proxy: generated mode table matches implementation", async () => {
  const spec = JSON.parse(await readFile(new URL("./proxy_modes.generated.json", import.meta.url), "utf8"));
  const byId = Object.fromEntries(spec.modes.map((m) => [m.id, m]));
  assert.equal(byId["http2-bridge"]?.status, "shipped");
  assert.equal(byId["tcp-smoltcp"]?.status, "spike");
  assert.equal(byId["http3-terminator"]?.status, "spike");
  const proxySource = await readFile(new URL("./grpc-dc-proxy.mjs", import.meta.url), "utf8");
  assert.match(proxySource, /serveDcToHttp2/, "shipped http2-bridge mode must use the bridge");
});

test("proxy: grpc-dc client -> grpc-dc-proxy -> HTTP/2 backend", { timeout: 120000 }, async (t) => {
  const backend = await startBackend();
  t.after(() => {
    backend.server.closeAllConnections?.();
    return backend.close();
  });
  const proxy = await startProxy({ port: await freePort(), backend: `127.0.0.1:${backend.port}`, host: "127.0.0.1" });
  t.after(() => {
    proxy.http.closeAllConnections?.();
    return proxy.close();
  });

  const offerer = await Peer.create();
  t.after(() => offerer.close());
  const ws = new WebSocket(`ws://127.0.0.1:${proxy.port}/`);
  t.after(() => ws.close());
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  const answer = new Promise((resolve) => {
    ws.onmessage = (event) => {
      const msg = JSON.parse(String(event.data));
      if (msg.kind === "answer") resolve(msg.sdp);
    };
  });
  ws.send(JSON.stringify({ kind: "offer", sdp: offerer.createOffer() }));
  offerer.handleAnswer(await answer);
  const endpoint = await offerer.connect();
  const dc = endpoint.openChannel({ label: "grpc" });
  const client = new EchoClient(new Channel(dc));

  const unary = await client.unary(new EchoRequest({ message: "hello" }));
  assert.equal(unary.message, "echo: hello");

  const ticks = [];
  for await (const res of await client.serverStream(new EchoRequest({ message: "tick", count: 3 }))) {
    ticks.push(res.index);
  }
  assert.deepEqual(ticks, [0, 1, 2]);

  await assert.rejects(
    client.unary(new EchoRequest({ message: "fail" })),
    (err) => err.code === 3,
  );
});
