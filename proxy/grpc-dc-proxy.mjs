#!/usr/bin/env node
// grpc-dc-proxy: a supported TCP <-> DataChannel proxy process.
//
// Generalizes the oracle test bridge (oracle/bridge.mjs) into a
// runnable service: grpc-dc clients (browser tabs or native
// peers) connect over WebRTC DataChannels; every call is
// translated to a real HTTP/2 gRPC stream against a stock
// backend (--backend host:port), so unmodified grpc-go /
// grpc-java / grpc-node servers become reachable from a
// browser with no grpc-web proxy in the page path and no
// changes to the backend.
//
//   node proxy/grpc-dc-proxy.mjs --backend 127.0.0.1:50051 [--port 8090]
//
// Signaling is the starter WebSocket offer/answer exchange
// ({kind:"offer",sdp} -> {kind:"answer",sdp}); serve this
// process behind any HTTPS tunnel (e.g. cloudflared) for
// remote browsers, exactly like the starter demo. gRPC
// compression is terminated here (see oracle/bridge.mjs):
// the DataChannel wire is always uncompressed.
//
// The smoltcp TCP-listener mode and HTTP/3 (QUIC) termination
// discussed for this proxy are follow-ups; the HTTP/2 bridge
// below is the shipped core. Most surrounding surface
// (per-language examples, tests, docs) is generated; this
// process and oracle/bridge.mjs are the hand-written kernel.

import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

import { WebSocketServer } from "../examples/starter/signal.mjs";
import { Peer } from "../webrtc/js/peer.js";
import { Endpoint } from "../js/index.js";
import { serveDcToHttp2 } from "../oracle/bridge.mjs";

export function startProxy({ port = 8090, backend, host = "0.0.0.0" } = {}) {
  if (!backend) throw new Error("grpc-dc-proxy: --backend host:port is required");
  const http = createServer((req, res) => {
    if (req.url === "/healthz") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end("ok\n");
    } else {
      res.writeHead(404);
      res.end("not found\n");
    }
  });
  const wss = new WebSocketServer({ server: http });
  let peers = 0;
  wss.on("connection", (ws) => {
    ws.on("message", async (data) => {
      let msg;
      try {
        msg = JSON.parse(String(data));
      } catch {
        return;
      }
      if (msg.kind !== "offer") return;
      const answerer = await Peer.create();
      peers += 1;
      const id = peers;
      try {
        ws.send(JSON.stringify({ kind: "answer", sdp: answerer.handleOffer(msg.sdp) }));
        const endpoint = await answerer.connect();
        endpoint.onchannel = (channel) => {
          console.log(`grpc-dc-proxy: peer ${id} channel -> http2 ${backend}`);
          const session = serveDcToHttp2({
            grpcAuthority: backend,
            endpoint: new Endpoint(channel, { parity: "even" }),
          });
          channel.onclose = () => session.close();
        };
        ws.on("close", () => answerer.close());
      } catch (err) {
        console.error(`grpc-dc-proxy: peer ${id} failed: ${err.message}`);
        await answerer.close();
      }
    });
  });
  return new Promise((resolve) => {
    http.listen(port, host, () => {
      console.log(`grpc-dc-proxy: signaling on http://${host}:${port} (ws), backend http2 ${backend}`);
      resolve({
        http,
        port: http.address().port,
        close: () =>
          new Promise((done) => {
            // Upgraded signaling sockets are not tracked by
            // http.Server.close(); destroy them first.
            for (const client of wss.clients) client.socket.destroy();
            http.close(done);
          }),
      });
    });
  });
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const value = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : fallback;
  };
  const backend = value("--backend");
  if (!backend) {
    console.error("usage: node proxy/grpc-dc-proxy.mjs --backend host:port [--port 8090]");
    process.exit(2);
  }
  await startProxy({ port: Number(value("--port", "8090")), backend });
}
