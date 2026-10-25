// TLS HTTP/2 front-end fixture for the Python and Go HTTP/2
// oracle tests: generates a self-signed localhost cert, serves
// a JS Echo server behind bridge serveHttp2ToDc with TLS, and
// prints "READY <port> <certPath>" on stdout. The JS HTTP/2
// tests exercise the same shape in-process; this fixture exists
// so non-JS clients can dial a real TLS+ALPN-h2 peer.

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Endpoint, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoResponse } from "../examples/echo_pb.js";
import { createEchoService } from "../examples/echo_grpc_dc.js";
import { serveHttp2ToDc } from "../../oracle/bridge.mjs";

const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    const suffix = ctx.metadata["x-echo"] ? ` [${ctx.metadata["x-echo"]}]` : "";
    return new EchoResponse({ message: `echo: ${req.message}${suffix}`, index: 0 });
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

const dir = mkdtempSync(join(tmpdir(), "http2-tls-fixture-"));
const cert = join(dir, "cert.pem");
const key = join(dir, "key.pem");
execFileSync("openssl", [
  "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
  "-days", "1", "-nodes", "-subj", "/CN=localhost",
  "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
], { stdio: "ignore" });

const [a, b] = memoryDataChannelPair();
const server = new Server();
server.addService(createEchoService(handlers));
server.serve(b);

const port = await new Promise((resolve) => {
  const s = createServer();
  s.listen(0, "127.0.0.1", () => {
    const p = s.address().port;
    s.close(() => resolve(p));
  });
});
await serveHttp2ToDc({
  port,
  endpoint: new Endpoint(a),
  tls: { cert: readFileSync(cert), key: readFileSync(key) },
});
console.log(`READY ${port} ${cert}`);
