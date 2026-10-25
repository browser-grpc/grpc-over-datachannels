// HTTP/2 oracle tests: generated clients call the official
// grpc-java server DIRECTLY over HTTP/2 (no TCP<->DataChannel
// bridge). src/http2.js is generated code.
// The TLS case dials the bridge's TLS HTTP/2 front-end (stdlib
// TLS + ALPN h2 on both sides) backed by a JS Echo server.
// Skips when the Java oracle is not built (Dockerfile.ci builds it).

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { Channel, Endpoint, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { runOracleScenarios } from "./oracle_driver.generated.js";
import { Http2DataChannel, http2Channel } from "../src/http2.js";
import { serveHttp2ToDc } from "../../oracle/bridge.mjs";

const ROOT = new URL("../..", import.meta.url).pathname;
const JAVA_DIR = `${ROOT}oracle/java`;

const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    if (req.delayMs > 0) await new Promise((resolve) => setTimeout(resolve, req.delayMs));
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

function javaClasspath(t) {
  const cpFile = `${JAVA_DIR}/target/cp.txt`;
  if (!existsSync(`${JAVA_DIR}/target/classes`) || !existsSync(cpFile)) {
    t.skip("java oracle not built (cd oracle/java && mvn package)");
    return null;
  }
  return `${JAVA_DIR}/target/classes:${readFileSync(cpFile, "utf8").trim()}`;
}

async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startJavaServer(t, port) {
  const cp = javaClasspath(t);
  if (!cp) return false;
  const proc = spawn("java", ["-cp", cp, "dc.oracle.OracleServer", String(port)], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => proc.kill());
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("java server did not start")), 30000);
    proc.stderr.on("data", (d) => {
      if (String(d).includes("READY")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.on("exit", (code) => reject(new Error(`java server exited ${code}`)));
  });
  return true;
}

test("http2: JS client -> grpc-java server directly (h2c)", { timeout: 180000 }, async (t) => {
  const port = await freePort();
  if (!(await startJavaServer(t, port))) return;
  const channel = http2Channel(`127.0.0.1:${port}`);
  t.after(() => channel.endpoint.dataChannel.close());
  const client = new EchoClient(channel);
  await runOracleScenarios(client, assert);

  const meta = await client.unary(new EchoRequest({ message: "hello" }), { metadata: { "x-echo": "meta" } });
  assert.equal(meta.message, "echo: hello [meta]");

  await assert.rejects(
    client.unary(new EchoRequest({ message: "", delayMs: 1500 }), { timeout: 300 }),
    (err) => err.code === StatusCode.DEADLINE_EXCEEDED,
  );

  await assert.rejects(
    channel.unary("/echo.Echo/Nope", new EchoRequest({ message: "x" }), EchoRequest, EchoResponse),
    (err) => err.code === StatusCode.UNIMPLEMENTED,
  );

  let count = 0;
  let last = -1;
  for await (const res of await client.serverStream(new EchoRequest({ message: "tick", count: 1000 }))) {
    count++;
    last = res.index;
  }
  assert.equal(count, 1000);
  assert.equal(last, 999);
});

test("http2: JS client (TLS) -> TLS HTTP/2 front-end -> JS server", { timeout: 180000 }, async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "http2-tls-"));
  const cert = join(dir, "cert.pem");
  const key = join(dir, "key.pem");
  try {
    execFileSync("openssl", [
      "req", "-x509", "-newkey", "rsa:2048", "-keyout", key, "-out", cert,
      "-days", "1", "-nodes", "-subj", "/CN=localhost",
      "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    ], { stdio: "ignore" });
  } catch {
    t.skip("openssl unavailable for TLS fixture");
    return;
  }
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers));
  server.serve(b);
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({
    port,
    endpoint: new Endpoint(a),
    tls: { cert: readFileSync(cert), key: readFileSync(key) },
  });
  t.after(() => http2Server.close());

  const dc = new Http2DataChannel(`127.0.0.1:${port}`, {
    secure: true,
    ca: readFileSync(cert),
    servername: "localhost",
  });
  const client = new EchoClient(new Channel(dc));
  const resp = await client.unary(new EchoRequest({ message: "hello" }));
  assert.equal(resp.message, "echo: hello");
  dc.close();
});
