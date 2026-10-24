import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "./signal.mjs";
import { Peer } from "../../webrtc/js/peer.js";
import { Server, StatusCode, StatusError } from "../../js/index.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const HERE = fileURLToPath(new URL(".", import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    if (req.delayMs > 0) await new Promise((r) => setTimeout(r, req.delayMs));
    const md = ctx?.metadata;
    const mv = typeof md?.get === "function" ? md.get("x-echo") : md?.["x-echo"];
    return new EchoResponse({ message: `echo: ${req.message}${mv ? ` [${mv}]` : ""}`, index: 0 });
  },
  async *serverStream(req) {
    if (req.message === "fail") throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    for (let i = 0; i < Math.max(0, req.count); i++) yield new EchoResponse({ message: req.message, index: i });
  },
  async clientStream(requests) {
    const parts = [];
    for await (const req of requests) parts.push(req.message);
    return new EchoResponse({ message: parts.join("+"), index: parts.length });
  },
  async *bidi(requests) {
    let index = 0;
    for await (const req of requests) {
      if (req.message === "fail") throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      yield new EchoResponse({ message: req.message, index: index++ });
    }
  },
};

const http = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    let rel = url.pathname === "/" ? "client.html" : decodeURIComponent(url.pathname.slice(1));
    // The page imports the repo runtime by absolute path
    // (/js/...); map those onto the repo root, everything else
    // is starter-local.
    const base = rel.startsWith("js/") || rel.startsWith("webrtc/") ? ROOT : HERE;
    if (base === ROOT) { /* rel already repo-relative */ } else { /* starter-local */ }
    const path = normalize(join(base, rel));
    if (!path.startsWith(base)) throw new Error("outside served dir");
    const body = await readFile(path);
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch { res.writeHead(404); res.end("not found"); }
});

const peers = new Map();
const wss = new WebSocketServer({ server: http });
wss.on("connection", (ws) => {
  const id = Math.random().toString(36).slice(2, 8);
  peers.set(id, ws);
  ws.on("message", async (data) => {
    const msg = JSON.parse(String(data));
    if (msg.kind === "offer") {
      const answerer = await Peer.create();
      const grpcServer = new Server();
      grpcServer.addService(createEchoService(handlers));
      const answer = answerer.handleOffer(msg.sdp);
      ws.send(JSON.stringify({ kind: "answer", sdp: answer }));
      const endpoint = await answerer.connect();
      endpoint.onchannel = (channel) => grpcServer.serve(channel);
      ws.on("close", () => answerer.close());
    }
  });
  ws.on("close", () => peers.delete(id));
});

http.listen(PORT, () => {
  console.log(`starter: open http://localhost:${PORT}/ in your browser`);
  console.log("starter: signaling is WebSocket on the same port; gRPC runs over the DataChannel");
});