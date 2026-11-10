// Browser -> native server with no signaling at all: this one
// HTTP server serves the page and the rendezvous descriptor
// (as static JSON at /rendezvous.json — in production it could
// be hardcoded in the page instead). The Echo service itself
// runs on a fixed RendezvousListener: one UDP socket, fixed
// ICE credentials and DTLS certificate. The page synthesizes
// the listener's SDP from the descriptor and dials it
// directly; no offer/answer ever crosses HTTP.
//
//   node examples/rendezvous/server.mjs
//   # open http://localhost:8080/ in your browser
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { networkInterfaces } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { Server } from "../../js/index.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../../js/src/rendezvous_server.js";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const HERE = fileURLToPath(new URL(".", import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

// The address browsers should dial: this host's outward IPv4,
// as a real deployment publishes its public address. (Firefox
// will not pair a non-loopback local candidate with a
// loopback remote candidate, so 127.0.0.1 is not published
// even for local runs.)
const hostIp =
  Object.values(networkInterfaces())
    .flat()
    .find((n) => n && n.family === "IPv4" && !n.internal)?.address ?? "127.0.0.1";

const handlers = {
  async unary(req) {
    return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
  },
  async *serverStream(req) {
    for (let i = 0; i < Math.max(0, req.count); i++) {
      yield new EchoResponse({ message: req.message, index: i });
    }
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.message);
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

const grpcServer = new Server();
grpcServer.addService(createEchoService(handlers));
const listener = await serveRendezvous(grpcServer, { address: "0.0.0.0", port: 0 });

const http = createServer(async (req, res) => {
  if (req.url === "/rendezvous.json") {
    // The whole signaling story: five static values. Cache
    // briefly (see .well-known guidance in SPEC-WEBRTC.md).
    res.writeHead(200, {
      "content-type": "application/json",
      "cache-control": "max-age=60",
    });
    res.end(JSON.stringify(listener.descriptor(hostIp)));
    return;
  }
  try {
    const url = new URL(req.url, "http://x");
    const rel = url.pathname === "/" ? "client.html" : decodeURIComponent(url.pathname.slice(1));
    // The page imports the repo runtime by absolute path
    // (/js/...); map those onto the repo root, everything else
    // is example-local.
    const base = rel.startsWith("js/") || rel.startsWith("webrtc/") ? ROOT : HERE;
    const path = normalize(join(base, rel));
    if (!path.startsWith(base)) throw new Error("outside served dir");
    const body = await readFile(path);
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end("not found");
  }
});

http.listen(PORT, () => {
  console.log(`rendezvous example: open http://localhost:${PORT}/ in your browser`);
  console.log("rendezvous example: descriptor at /rendezvous.json; gRPC runs over the DataChannel");
  console.log("rendezvous descriptor:", JSON.stringify(listener.descriptor(hostIp)));
});
