import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "../starter/signal.mjs";
import { Peer } from "../../webrtc/js/peer.js";
import { Server } from "../../js/index.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const HERE = fileURLToPath(new URL(".", import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm" };
const handlers = {
  async unary(req) { return new EchoResponse({ message: `echo: ${req.message}`, index: 0 }); },
  async *serverStream(req) { for (let i = 0; i < Math.max(0, req.count); i++) yield new EchoResponse({ message: req.message, index: i }); },
  async clientStream(requests) { const p = []; for await (const r of requests) p.push(r.message); return new EchoResponse({ message: p.join("+"), index: p.length }); },
  async *bidi(requests) { let i = 0; for await (const r of requests) yield new EchoResponse({ message: r.message, index: i++ }); },
};
const http = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    const rel = url.pathname === "/" ? "index.html" : decodeURIComponent(url.pathname.slice(1));
    const base = (rel.startsWith("js/") || rel.startsWith("webrtc/") || rel.startsWith("browser-test/")) ? ROOT : HERE;
    const path = normalize(join(base, rel));
    if (!path.startsWith(base)) throw new Error("outside served dir");
    const body = await readFile(path);
    res.writeHead(200, {
      "content-type": MIME[extname(path)] ?? "application/octet-stream",
      // Lua/Rust native Wasm clients use a SharedArrayBuffer
      // worker mailbox; that needs cross-origin isolation.
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    res.end(body);
  } catch { res.writeHead(404); res.end("not found"); }
});
const wss = new WebSocketServer({ server: http });
wss.on("connection", (ws) => {
  ws.on("message", async (data) => {
    const msg = JSON.parse(String(data));
    if (msg.kind === "offer") {
      const answerer = await Peer.create();
      const grpcServer = new Server();
      grpcServer.addService(createEchoService(handlers));
      ws.send(JSON.stringify({ kind: "answer", sdp: answerer.handleOffer(msg.sdp) }));
      const endpoint = await answerer.connect();
      endpoint.onchannel = (channel) => grpcServer.serve(channel);
      ws.on("close", () => answerer.close());
    }
  });
});
http.listen(PORT, () => console.log(`browser examples: open http://localhost:${PORT}/`));
// NOTE: Lua's native Wasm client blocks its worker on a
// SharedArrayBuffer mailbox while waiting for replies; under
// sustained load it can miss frames the JS runtime delivers
// during its startup window. It is listed in the index with
// that caveat until its startup race is fixed upstream.