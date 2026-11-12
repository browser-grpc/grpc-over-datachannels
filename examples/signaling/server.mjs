// Browser -> native server with no signaling server: this one
// HTTP server serves the page AND the generated POST signaling
// endpoint (/grpc-dc/signal). The page POSTs its ICE-complete
// offer, this process answers from its shared PeerMux, and the
// Echo calls then run peer-to-peer over the "grpc" DataChannel.
//
//   node examples/signaling/server.mjs
//   # open http://localhost:8080/ in your browser
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { Server } from "../../js/index.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";
import { signalingHandler } from "../../js/src/signaling_server.js";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const HERE = fileURLToPath(new URL(".", import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

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
const signal = signalingHandler(grpcServer);

const http = createServer(async (req, res) => {
  if (await signal(req, res)) return; // POST /grpc-dc/signal
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
  console.log(`signaling example: open http://localhost:${PORT}/ in your browser`);
  console.log("signaling example: one POST to /grpc-dc/signal; gRPC runs over the DataChannel");
});
