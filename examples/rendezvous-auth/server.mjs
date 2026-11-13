// Rendezvous + WebAuthn issuer example: one HTTP server
// serves the page and the rendezvous descriptor, verifies
// WebAuthn register/login ceremonies, and mints rendezvous
// bearer tokens. The gRPC listener itself
// (serveRendezvous with options.auth) never sees WebAuthn
// data — it only verifies the HMAC token the page presents
// per call.
//
//   node examples/rendezvous-auth/server.mjs
//   # open http://localhost:8080/ and use a passkey /
//   # platform authenticator (WebAuthn needs localhost or
//   # HTTPS; rpId is derived from the Host header)
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { networkInterfaces } from "node:os";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { Server } from "../../js/index.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";
import { serveRendezvous } from "../../js/src/rendezvous_server.js";
import { createIssuer } from "./issuer.mjs";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const HERE = fileURLToPath(new URL(".", import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const SECRET = process.env.RENDEZVOUS_SECRET || "dev-secret-change-me";
const MIME = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript" };

const hostIp =
  Object.values(networkInterfaces())
    .flat()
    .find((n) => n && n.family === "IPv4" && !n.internal)?.address ?? "127.0.0.1";

const handlers = {
  async unary(req, ctx) {
    return new EchoResponse({ message: `echo: ${req.message} (sub=${ctx.claims?.sub})`, index: 0 });
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
const listener = await serveRendezvous(grpcServer, {
  address: "0.0.0.0",
  port: 0,
  auth: { secret: SECRET, scopes: { "/echo.Echo/Unary": ["read"] } },
});

const json = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const readJson = async (req) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
};

const http = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://x");
    if (url.pathname === "/rendezvous.json") {
      res.writeHead(200, { "content-type": "application/json", "cache-control": "max-age=60" });
      res.end(JSON.stringify(listener.descriptor(hostIp)));
      return;
    }
    if (url.pathname.startsWith("/auth/")) {
      // rpId/origin follow the page origin so the same issuer
      // works on localhost and on a deployed HTTPS origin.
      const origin = `http://${req.headers.host}`;
      const rpId = new URL(origin).hostname;
      // Ceremonies are stateful (see issuer.mjs): one shared
      // issuer per page origin.
      http.issuers ??= new Map();
      if (!http.issuers.has(origin)) {
        http.issuers.set(origin, createIssuer({ secret: SECRET, rpId, origin }));
      }
      const shared = http.issuers.get(origin);
      const body = await readJson(req);
      const name = String(body.name || "alice");
      if (url.pathname === "/auth/register/options") return json(res, 200, shared.registrationOptions(name));
      if (url.pathname === "/auth/register/verify") return json(res, 200, await shared.verifyRegistration(name, body.response));
      if (url.pathname === "/auth/login/options") return json(res, 200, shared.authenticationOptions(name));
      if (url.pathname === "/auth/login/verify") return json(res, 200, await shared.verifyAuthentication(name, body.response));
      return json(res, 404, { error: "unknown auth route" });
    }
    const rel = url.pathname === "/" ? "client.html" : decodeURIComponent(url.pathname.slice(1));
    const base = rel.startsWith("js/") || rel.startsWith("webrtc/") ? ROOT : HERE;
    const path = normalize(join(base, rel));
    if (!path.startsWith(base)) throw new Error("outside served dir");
    const body = await readFile(path);
    res.writeHead(200, { "content-type": MIME[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch (e) {
    json(res, 400, { error: String(e?.message ?? e) });
  }
});

http.listen(PORT, () => {
  console.log(`rendezvous-auth example: open http://localhost:${PORT}/ in your browser`);
  console.log("flow: register a passkey, log in, then the page dials the rendezvous listener with the minted token");
});
