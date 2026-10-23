// Oracle tests: the official grpc-java implementation, bridged over
// TCP<->DataChannel by oracle/bridge.mjs, must agree with our runtimes
// on every case of the Racket-generated scenario file
// (fixtures/oracle_scenarios.txt). Skips when the Java oracle or the
// Rust example binaries are not built (Dockerfile.ci builds both).

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import test from "node:test";

import { Channel, Endpoint, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoResponse } from "../examples/echo_pb.js";
import { runOracleScenarios } from "./oracle_driver.generated.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { StdioChannel, serveDcToHttp2, serveHttp2ToDc } from "../../oracle/bridge.mjs";

const ROOT = new URL("../..", import.meta.url).pathname;
const JAVA_DIR = `${ROOT}oracle/java`;
const SCENARIOS = `${ROOT}fixtures/oracle_scenarios.txt`;
const RUST_SERVER = `${ROOT}rust/target/debug/examples/echo_server_stdio`;

const handlers = {
  async unary(req) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
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

async function runJavaClient(t, port, { compress = false } = {}) {
  const cp = javaClasspath(t);
  if (!cp) return;
  const args = ["-cp", cp];
  if (compress) args.push("-Doracle.compress=gzip");
  args.push("dc.oracle.OracleClient", String(port), SCENARIOS);
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
