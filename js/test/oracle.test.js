// Oracle tests: the official grpc-java implementation, bridged over
// TCP<->DataChannel by oracle/bridge.mjs, must agree with our runtimes
// on every case of the Racket-generated scenario file
// (fixtures/oracle_scenarios.txt). Skips when the Java oracle or the
// Rust example binaries are not built (Dockerfile.ci builds both).

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { Channel, Endpoint, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { startAgent } from "../../proxy/grpc-dc-agent.mjs";
import { dialDc, startIngressProxy } from "../../proxy/grpc-dc-proxy.mjs";
import { runOracleScenarios } from "./oracle_driver.generated.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { StdioChannel, serveDcToHttp2, serveHttp2ToDc } from "../../oracle/bridge.mjs";

const ROOT = new URL("../..", import.meta.url).pathname;
const JAVA_DIR = `${ROOT}oracle/java`;
const SCENARIOS = `${ROOT}fixtures/oracle_scenarios.txt`;
const RUST_SERVER = `${ROOT}rust/target/debug/examples/echo_server_stdio`;

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
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    if (req.delayMs > 0) await new Promise((resolve) => setTimeout(resolve, req.delayMs));
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
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
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

function runJava(args, t) {
  return new Promise((resolve, reject) => {
    const proc = spawn("java", args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    proc.on("error", reject);
    proc.on("exit", (code) => resolve({ code, stdout, stderr }));
    t.after(() => proc.kill());
  });
}

async function startJavaServer(t, port, { compress = false } = {}) {
  const cp = javaClasspath(t);
  if (!cp) return null;
  const args = ["-cp", cp];
  if (compress) args.push("-Doracle.compress=gzip");
  args.push("dc.oracle.OracleServer", String(port));
  const proc = spawn("java", args, {
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
  return proc;
}

async function runJavaClient(t, port, { compress = false, props = {}, scenarios = SCENARIOS } = {}) {
  const cp = javaClasspath(t);
  if (!cp) return;
  const args = ["-cp", cp];
  if (compress) args.push("-Doracle.compress=gzip");
  for (const [key, value] of Object.entries(props)) args.push(`-Doracle.${key}=${value}`);
  args.push("dc.oracle.OracleClient", String(port), scenarios);
  const { code, stdout, stderr } = await runJava(args, t);
  assert.equal(code, 0, `oracle client failed:\n${stdout}\n${stderr}`);
  assert.match(stdout, /ORACLE CLIENT: ALL OK/);
}

test("oracle: official Java client -> bridge -> JS server", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers));
  server.serve(b);
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({ port, endpoint: new Endpoint(a) });
  t.after(() => http2Server.close());
  await runJavaClient(t, port);
});

test("oracle: JS client -> bridge -> official Java server", { timeout: 180000 }, async (t) => {
  const javaPort = await freePort();
  if (!(await startJavaServer(t, javaPort))) return;
  const [a, b] = memoryDataChannelPair();
  const bridgeEndpoint = new Endpoint(a, { parity: "even" });
  const session = serveDcToHttp2({ grpcAuthority: `127.0.0.1:${javaPort}`, endpoint: bridgeEndpoint });
  t.after(() => session.close());
  const client = new EchoClient(new Channel(b));
  await runOracleScenarios(client, assert);
});

test("oracle: gzip Java client -> bridge decompresses -> JS server", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers));
  server.serve(b);
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({ port, endpoint: new Endpoint(a) });
  t.after(() => http2Server.close());
  await runJavaClient(t, port, { compress: true });
});

test("oracle: JS client -> bridge decompresses -> gzip Java server", { timeout: 180000 }, async (t) => {
  const javaPort = await freePort();
  if (!(await startJavaServer(t, javaPort, { compress: true }))) return;
  const [a, b] = memoryDataChannelPair();
  const bridgeEndpoint = new Endpoint(a, { parity: "even" });
  const session = serveDcToHttp2({ grpcAuthority: `127.0.0.1:${javaPort}`, endpoint: bridgeEndpoint });
  t.after(() => session.close());
  const client = new EchoClient(new Channel(b));
  await runOracleScenarios(client, assert);
});

// ---------------------------------------------------------------------------
// Gap coverage vs grpc-java (metadata, deadlines, unknown
// methods, large streams, TLS, and the redone ingress proxy).
// The Java oracle implements the same canonical Echo semantics
// (x-echo reflection, delayMs, per-shape fail) as our servers.
// ---------------------------------------------------------------------------

function jsServerPair(t) {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers));
  server.serve(b);
  return a;
}

test("oracle gaps: JS client metadata + deadline + unknown + big stream -> Java server", { timeout: 180000 }, async (t) => {
  const javaPort = await freePort();
  if (!(await startJavaServer(t, javaPort))) return;
  const [a, b] = memoryDataChannelPair();
  const session = serveDcToHttp2({ grpcAuthority: `127.0.0.1:${javaPort}`, endpoint: new Endpoint(a, { parity: "even" }) });
  t.after(() => session.close());
  const channel = new Channel(b);
  const client = new EchoClient(channel);

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

test("oracle gaps: Java client metadata + deadline -> JS server", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({ port, endpoint: new Endpoint(jsServerPair(t)) });
  t.after(() => http2Server.close());
  await runJavaClient(t, port, { props: { metadata: "meta" } });

  const dir = mkdtempSync(join(tmpdir(), "oracle-deadline-"));
  const scenarios = join(dir, "scenarios.txt");
  writeFileSync(scenarios, "DEADLINE 1500 300\nUNARY hello\n");
  await runJavaClient(t, port, { scenarios });
});

test("oracle gaps: Java client (TLS) -> bridge (TLS) -> JS server", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  const dir = mkdtempSync(join(tmpdir(), "oracle-tls-"));
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
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({
    port,
    endpoint: new Endpoint(jsServerPair(t)),
    tls: { cert: readFileSync(cert), key: readFileSync(key) },
  });
  t.after(() => http2Server.close());
  await runJavaClient(t, port, { props: { tlsCert: cert } });
});

test("oracle gaps: official Java client -> ingress proxy -> grpc-dc server (WebRTC-Direct)", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  const agent = await startAgent({});
  t.after(() => agent.close());
  const dc = await dialDc(agent.multiaddr);
  const proxy = await startIngressProxy({
    dcStackEndpoint: dc.endpoint,
    dc,
    http2Port: await freePort(),
  });
  t.after(() => proxy.close());
  await runJavaClient(t, proxy.http2Port);
});

test("oracle: official Java client -> bridge -> Rust server", { timeout: 180000 }, async (t) => {
  if (!javaClasspath(t)) return;
  if (!existsSync(RUST_SERVER)) {
    t.skip("rust echo_server_stdio not built");
    return;
  }
  const proc = spawn(RUST_SERVER, { stdio: ["pipe", "pipe", "inherit"] });
  t.after(() => proc.kill());
  const endpoint = new Endpoint(new StdioChannel(proc.stdout, proc.stdin));
  const port = await freePort();
  const http2Server = await serveHttp2ToDc({ port, endpoint });
  t.after(() => http2Server.close());
  await runJavaClient(t, port);
});
