// Rust proxy tests: the homegrown Rust HTTP/2 proxy
// (rust/examples/grpc_dc_proxy.rs over grpc_dc::http2) in both
// directions against stock Node HTTP/2 gRPC peers:
//
//   1. stock HTTP/2 client -> Rust proxy -> Rust grpc-dc Echo
//      server (direct_echo serve, WebRTC-Direct)
//   2. Rust grpc-dc client (direct_echo dial) -> Rust proxy ->
//      stock HTTP/2 Echo server
//
// The Rust HTTP/2 stack is exercised against Node's HTTP/2
// (HPACK/flow control/framing interop), not against itself.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import http2 from "node:http2";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import test from "node:test";

import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";
import { LpmParser, lpm } from "../oracle/bridge.mjs";

const ROOT = new URL("..", import.meta.url).pathname;

function freePort() {
  const probe = createServer();
  return new Promise((resolve) => {
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

function start(cmd, args, env = {}) {
  const child = spawn(cmd, args, {
    cwd: ROOT,
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.output = "";
  child.stdout.on("data", (d) => (child.output += d));
  child.stderr.on("data", (d) => (child.output += d));
  return child;
}

async function waitFor(child, pattern, what, timeoutMs = 120000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const m = child.output.match(pattern);
    if (m) return m;
    if (child.exitCode !== null) {
      throw new Error(`${what} exited ${child.exitCode}:\n${child.output}`);
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timeout waiting for ${what}:\n${child.output}`);
}

function stop(child) {
  if (child && child.exitCode === null) child.kill("SIGKILL");
}

test.before(() => {
  const build = spawnSync(
    "cargo",
    ["build", "--features", "webrtc", "--example", "grpc_dc_proxy", "--example", "direct_echo"],
    { cwd: `${ROOT}/rust`, stdio: "inherit", timeout: 600000 },
  );
  assert.equal(build.status, 0, "cargo build proxy examples");
});

function http2Call(port, path, payload) {
  return new Promise((resolve, reject) => {
    const session = http2.connect(`http://127.0.0.1:${port}`);
    const stream = session.request({
      ":path": path,
      ":method": "POST",
      ":scheme": "http",
      "content-type": "application/grpc",
      te: "trailers",
    });
    const parser = new LpmParser("identity");
    const messages = [];
    let trailers = null;
    stream.on("data", (chunk) => messages.push(...parser.push(chunk)));
    stream.on("trailers", (t) => (trailers = t));
    stream.on("error", reject);
    stream.on("end", () => {
      session.close();
      resolve({ messages, trailers });
    });
    stream.end(lpm(payload));
  });
}

test("rust proxy direction 1: stock HTTP/2 client -> proxy -> grpc-dc server", { timeout: 180000 }, async (t) => {
  const server = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["serve"], {
    DIRECT_ADDR: "127.0.0.1:0",
  });
  t.after(() => stop(server));
  const multiaddr = (await waitFor(server, /MULTIADDR (\S+)/, "direct_echo server"))[1];

  const port = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-dial", multiaddr, "--http2", String(port),
  ]);
  t.after(() => stop(proxy));
  await waitFor(proxy, /ingress http2=/, "rust proxy ingress");

  const unary = await http2Call(
    port, "/echo.Echo/Unary",
    EchoRequest.encode(new EchoRequest({ message: "hello" })),
  );
  assert.equal(unary.trailers["grpc-status"], "0");
  assert.equal(EchoResponse.decode(unary.messages[0]).message, "echo: hello");

  const stream = await http2Call(
    port, "/echo.Echo/ServerStream",
    EchoRequest.encode(new EchoRequest({ message: "tick", count: 3 })),
  );
  assert.equal(stream.trailers["grpc-status"], "0");
  assert.deepEqual(stream.messages.map((m) => EchoResponse.decode(m).index), [0, 1, 2]);
  console.log("rust proxy direction 1 OK");
});

function stockEchoServer(port) {
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    const parser = new LpmParser(headers["grpc-encoding"] ?? "identity");
    const respond = (payloads, status = "0") => {
      stream.respond(
        { ":status": 200, "content-type": "application/grpc" },
        { waitForTrailers: true },
      );
      for (const p of payloads) stream.write(lpm(p));
      stream.end();
      stream.on("wantTrailers", () => stream.sendTrailers({ "grpc-status": status }));
    };
    // respond() must register wantTrailers before end(); the
    // handler below defers until request end.
    const pending = [];
    stream.on("data", (chunk) => pending.push(...parser.push(chunk)));
    stream.on("end", () => {
      const req = EchoRequest.decode(pending[0]);
      if (headers[":path"] === "/echo.Echo/Unary") {
        respond([EchoResponse.encode(new EchoResponse({ message: `echo: ${req.message}`, index: 0 }))]);
      } else if (headers[":path"] === "/echo.Echo/ServerStream") {
        respond([0, 1, 2].map((i) =>
          EchoResponse.encode(new EchoResponse({ message: req.message, index: i }))));
      } else {
        respond([], "12");
      }
    });
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(server)));
}

function javaClasspath() {
  const target = `${ROOT}/oracle/java/target`;
  if (!existsSync(`${target}/cp.txt`) || !existsSync(`${target}/classes`)) return null;
  return `${target}/classes:${readFileSync(`${target}/cp.txt`, "utf8").trim()}`;
}

test("rust proxy direction 1 (oracle): grpc-java client -> proxy -> grpc-dc server", { timeout: 180000 }, async (t) => {
  const cp = javaClasspath();
  if (!cp) {
    console.log("skip: java oracle not built");
    return;
  }
  const server = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["serve"], {
    DIRECT_ADDR: "127.0.0.1:0",
  });
  t.after(() => stop(server));
  const multiaddr = (await waitFor(server, /MULTIADDR (\S+)/, "direct_echo server"))[1];

  const port = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-dial", multiaddr, "--http2", String(port),
  ]);
  t.after(() => stop(proxy));
  await waitFor(proxy, /ingress http2=/, "rust proxy ingress");

  // Subset of the oracle scenarios that the generated
  // direct_echo service implements (no fail/metadata cases).
  const scenarios = `${tmpdir()}/rust-proxy-oracle-scenarios.txt`;
  writeFileSync(scenarios, "UNARY hello\nSERVER_STREAM tick 3\nCLIENT_STREAM a b c\nBIDI x y\n");
  const client = spawn("java", ["-cp", cp, "dc.oracle.OracleClient", String(port), scenarios], {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  client.stdout.on("data", (d) => (out += d));
  client.stderr.on("data", (d) => (out += d));
  const code = await new Promise((resolve) => client.on("close", resolve));
  assert.equal(code, 0, out);
  assert.match(out, /ORACLE CLIENT: ALL OK/);
  console.log("rust proxy direction 1 oracle OK");
});

test("rust proxy direction 2 (oracle): grpc-dc client -> proxy -> grpc-java server", { timeout: 180000 }, async (t) => {
  const cp = javaClasspath();
  if (!cp) {
    console.log("skip: java oracle not built");
    return;
  }
  const backendPort = await freePort();
  const backend = spawn("java", ["-cp", cp, "dc.oracle.OracleServer", String(backendPort)], {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => stop(backend));
  backend.output = "";
  backend.stdout.on("data", (d) => (backend.output += d));
  backend.stderr.on("data", (d) => (backend.output += d));
  await waitFor(backend, /READY/, "java oracle server");

  const dcPort = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort), "--http2-dial", `127.0.0.1:${backendPort}`,
  ]);
  t.after(() => stop(proxy));
  const multiaddr = (await waitFor(proxy, /dc-listen .*?\((\S+)\)/, "rust proxy dc-listen"))[1];

  const client = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["dial", multiaddr]);
  await waitFor(client, /direct-echo OK/, "direct_echo client");
  stop(client);
  console.log("rust proxy direction 2 oracle OK");
});

test("rust proxy direction 2: grpc-dc client -> proxy -> stock HTTP/2 server", { timeout: 180000 }, async (t) => {
  const backendPort = await freePort();
  const backend = await stockEchoServer(backendPort);
  t.after(() => backend.close());

  const dcPort = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort), "--http2-dial", `127.0.0.1:${backendPort}`,
  ]);
  t.after(() => stop(proxy));
  const multiaddr = (await waitFor(proxy, /dc-listen .*?\((\S+)\)/, "rust proxy dc-listen"))[1];

  const client = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["dial", multiaddr]);
  const done = waitFor(client, /direct-echo OK/, "direct_echo client");
  await done;
  stop(client);
  console.log("rust proxy direction 2 OK");
});
