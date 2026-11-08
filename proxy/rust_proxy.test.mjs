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
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import http2 from "node:http2";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import test from "node:test";

const CERT = readFileSync("webrtc/js/test/fixtures/turn_tls_cert.pem");
const KEY = readFileSync("webrtc/js/test/fixtures/turn_tls_key.pem");

import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";
import { EchoClient, createEchoService } from "../js/examples/echo_grpc_dc.js";
import { Channel, Server, StatusCode, StatusError } from "../js/index.js";
import { acceptDirectEndpoint, directClientEndpoint, directListener } from "../js/src/webrtc_direct.js";
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
    ["build", "--features", "webrtc,http2-tls", "--example", "grpc_dc_proxy", "--example", "direct_echo"],
    { cwd: `${ROOT}/rust`, stdio: "inherit", timeout: 600000 },
  );
  assert.equal(build.status, 0, "cargo build proxy examples");
});

function http2Call(port, path, payload, tlsOptions = null) {
  return new Promise((resolve, reject) => {
    const session = tlsOptions
      ? http2.connect(`https://127.0.0.1:${port}`, tlsOptions)
      : http2.connect(`http://127.0.0.1:${port}`);
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

function secureEchoServer(port, cert, key) {
  const backend = http2.createSecureServer({ cert, key, allowHTTP1: false });
  backend.on("stream", (stream, headers) => {
    const parser = new LpmParser(headers["grpc-encoding"] ?? "identity");
    const pending = [];
    stream.on("data", (chunk) => pending.push(...parser.push(chunk)));
    stream.on("end", () => {
      const req = EchoRequest.decode(pending[0]);
      stream.respond(
        { ":status": 200, "content-type": "application/grpc" },
        { waitForTrailers: true },
      );
      if (headers[":path"] === "/echo.Echo/Unary") {
        stream.end(lpm(EchoResponse.encode(
          new EchoResponse({ message: `echo: ${req.message}`, index: 0 }))));
      } else {
        for (let i = 0; i < 3; i++) {
          stream.write(lpm(EchoResponse.encode(
            new EchoResponse({ message: req.message, index: i }))));
        }
        stream.end();
      }
      stream.on("wantTrailers", () => stream.sendTrailers({ "grpc-status": "0" }));
    });
  });
  return new Promise((resolve) => backend.listen(port, "127.0.0.1", () => resolve(backend)));
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

test("rust proxy direction 1 (tls): stock HTTPS client -> proxy -> grpc-dc server", { timeout: 180000 }, async (t) => {
  const server = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["serve"], {
    DIRECT_ADDR: "127.0.0.1:0",
  });
  t.after(() => stop(server));
  const multiaddr = (await waitFor(server, /MULTIADDR (\S+)/, "direct_echo server"))[1];

  const port = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-dial", multiaddr, "--http2", String(port),
    "--tls-cert", "webrtc/js/test/fixtures/turn_tls_cert.pem",
    "--tls-key", "webrtc/js/test/fixtures/turn_tls_key.pem",
  ]);
  t.after(() => stop(proxy));
  await waitFor(proxy, /ingress http2=/, "rust proxy tls ingress");

  const unary = await http2Call(
    port, "/echo.Echo/Unary",
    EchoRequest.encode(new EchoRequest({ message: "hello" })),
    { ca: CERT },
  );
  assert.equal(unary.trailers["grpc-status"], "0");
  assert.equal(EchoResponse.decode(unary.messages[0]).message, "echo: hello");
  console.log("rust proxy direction 1 tls OK");
});

test("rust proxy direction 2 (tls): grpc-dc client -> proxy -> HTTPS backend", { timeout: 180000 }, async (t) => {
  const backendPort = await freePort();
  const backend = await secureEchoServer(backendPort, CERT, KEY);
  t.after(() => backend.close());

  const dcPort = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort), "--http2-dial", `127.0.0.1:${backendPort}`,
    "--http2-tls", "--insecure-skip-verify",
  ]);
  t.after(() => stop(proxy));
  const multiaddr = (await waitFor(proxy, /dc-listen .*?\((\S+)\)/, "rust proxy dc-listen"))[1];

  const client = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["dial", multiaddr]);
  await waitFor(client, /direct-echo OK/, "direct_echo client");
  stop(client);
  console.log("rust proxy direction 2 tls OK");
});

test("rust proxy direction 2 (tls-ca): CA-signed backend verifies, wrong CA rejected", { timeout: 180000 }, async (t) => {
  // Mint a throwaway CA and a leaf signed by it (SAN localhost)
  // with the openssl CLI from the CI image; no fixtures checked
  // in, no network.
  const dir = mkdtempSync(`${tmpdir()}/grpc-dc-ca-`);
  const ssl = (args) => {
    const r = spawnSync("openssl", args, { encoding: "utf8" });
    assert.equal(r.status, 0, `openssl ${args[0]}: ${r.stderr}`);
  };
  ssl(["req", "-x509", "-newkey", "rsa:2048", "-keyout", `${dir}/ca.key`,
    "-out", `${dir}/ca.crt`, "-days", "2", "-nodes", "-subj", "/CN=grpc-dc-test-ca",
    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"]);
  ssl(["req", "-x509", "-newkey", "rsa:2048", "-keyout", `${dir}/wrong.key`,
    "-out", `${dir}/wrong.crt`, "-days", "2", "-nodes", "-subj", "/CN=other-ca",
    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"]);
  ssl(["req", "-newkey", "rsa:2048", "-keyout", `${dir}/srv.key`,
    "-out", `${dir}/srv.csr`, "-nodes", "-subj", "/CN=localhost"]);
  writeFileSync(`${dir}/san.cnf`,
    "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n");
  ssl(["x509", "-req", "-in", `${dir}/srv.csr`, "-CA", `${dir}/ca.crt`,
    "-CAkey", `${dir}/ca.key`, "-CAcreateserial", "-out", `${dir}/srv.crt`,
    "-days", "2", "-extfile", `${dir}/san.cnf`]);

  const backendPort = await freePort();
  const backend = await secureEchoServer(
    backendPort, readFileSync(`${dir}/srv.crt`), readFileSync(`${dir}/srv.key`));
  t.after(() => backend.close());

  // Verified path: the proxy pins the test CA and the server
  // name; the call must succeed end to end.
  const dcPort = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort), "--http2-dial", `127.0.0.1:${backendPort}`,
    "--http2-tls", "--tls-ca", `${dir}/ca.crt`, "--tls-server-name", "localhost",
  ]);
  t.after(() => stop(proxy));
  const multiaddr = (await waitFor(proxy, /dc-listen .*?\((\S+)\)/, "rust proxy dc-listen"))[1];
  const client = start(`${ROOT}/rust/target/debug/examples/direct_echo`, ["dial", multiaddr]);
  await waitFor(client, /direct-echo OK/, "direct_echo client via tls-ca proxy");
  stop(client);
  console.log("direction 2 tls-ca verified OK");

  // Wrong CA: verification must fail at proxy startup (the
  // backend connection is established before dc-listen prints).
  const dcPort2 = await freePort();
  const badProxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort2), "--http2-dial", `127.0.0.1:${backendPort}`,
    "--http2-tls", "--tls-ca", `${dir}/wrong.crt`, "--tls-server-name", "localhost",
  ]);
  t.after(() => stop(badProxy));
  const code = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), 15000);
    badProxy.on("close", (c) => { clearTimeout(timer); resolve(c); });
  });
  assert.notEqual(code, null, "proxy with wrong CA must fail, not serve");
  assert.notEqual(code, 0);
  console.log("direction 2 tls-ca wrong CA rejected OK");
});

// Backend for the error-path legs: fails on demand, streams
// slowly until cancelled, and records what the proxy forwarded.
function errorBackend(port, observed) {
  const server = http2.createServer();
  const sessions = new Set();
  server.on("session", (s) => { sessions.add(s); s.on("close", () => sessions.delete(s)); });
  server.on("stream", (stream, headers) => {
    const parser = new LpmParser(headers["grpc-encoding"] ?? "identity");
    const pending = [];
    stream.on("data", (chunk) => pending.push(...parser.push(chunk)));
    stream.on("end", () => {
      observed.headers = headers;
      const req = EchoRequest.decode(pending[0]);
      const respondHead = () => stream.respond(
        { ":status": 200, "content-type": "application/grpc" }, { waitForTrailers: true });
      if (headers[":path"] === "/echo.Echo/ServerStream" && req.message === "slow-stream") {
        respondHead();
        stream.write(lpm(EchoResponse.encode(new EchoResponse({ message: req.message, index: 0 }))));
        let i = 1;
        const timer = setInterval(() => {
          if (stream.destroyed) { clearInterval(timer); return; }
          stream.write(lpm(EchoResponse.encode(new EchoResponse({ message: req.message, index: i++ }))));
        }, 250);
        stream.on("close", () => { observed.cancelled = true; clearInterval(timer); });
        stream.on("wantTrailers", () => stream.sendTrailers({ "grpc-status": "0" }));
        return;
      }
      if (req.message === "fail") {
        respondHead();
        stream.end();
        stream.on("wantTrailers", () => stream.sendTrailers({
          "grpc-status": "3", "grpc-message": "asked to fail",
        }));
        return;
      }
      if (req.message === "slow") {
        setTimeout(() => {
          if (stream.destroyed) return;
          respondHead();
          stream.end(lpm(EchoResponse.encode(new EchoResponse({ message: "slow done", index: 0 }))));
          stream.on("wantTrailers", () => stream.sendTrailers({ "grpc-status": "0" }));
        }, 800);
        return;
      }
      respondHead();
      stream.end(lpm(EchoResponse.encode(new EchoResponse({ message: `echo: ${req.message}`, index: 0 }))));
      stream.on("wantTrailers", () => stream.sendTrailers({ "grpc-status": "0" }));
    });
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () =>
    resolve({ server, destroy: () => { for (const s of sessions) s.destroy(); server.close(); } })));
}

async function direction2Client(t, backendPort) {
  const dcPort = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort), "--http2-dial", `127.0.0.1:${backendPort}`,
  ]);
  t.after(() => stop(proxy));
  const multiaddr = (await waitFor(proxy, /dc-listen .*?\((\S+)\)/, "rust proxy dc-listen"))[1];
  const endpoint = await directClientEndpoint(multiaddr);
  t.after(async () => { await endpoint.directEndpoint.closeDirect?.() ?? endpoint.directEndpoint.close(); });
  return new EchoClient(new Channel(endpoint));
}

test("rust proxy direction 2 error paths: backend status, deadline, cancel, backend down", { timeout: 180000 }, async (t) => {
  const observed = { cancelled: false, headers: null };
  const backendPort = await freePort();
  const backend = await errorBackend(backendPort, observed);
  const client = await direction2Client(t, backendPort);

  // Non-OK backend status + message reach the grpc-dc client.
  await assert.rejects(client.unary(new EchoRequest({ message: "fail" })), (err) => {
    assert.equal(err.code, StatusCode.INVALID_ARGUMENT);
    assert.ok(err.message.includes("asked to fail"), err.message);
    return true;
  });
  console.log("direction 2 backend status OK");

  // Deadline: the client timeout is forwarded as grpc-timeout
  // and enforced locally while the backend is still working.
  await assert.rejects(client.unary(new EchoRequest({ message: "slow" }), { timeout: 150 }), (err) => {
    assert.equal(err.code, StatusCode.DEADLINE_EXCEEDED);
    return true;
  });
  assert.ok(observed.headers["grpc-timeout"], "proxy must forward grpc-timeout to the backend");
  console.log("direction 2 deadline OK");

  // Cancellation: aborting mid-stream resets the backend stream.
  const controller = new AbortController();
  const stream = await client.serverStream(
    new EchoRequest({ message: "slow-stream" }), { signal: controller.signal });
  const iter = stream[Symbol.asyncIterator]();
  const first = await iter.next();
  assert.equal(first.value.index, 0);
  controller.abort();
  await assert.rejects(iter.next(), (err) => {
    assert.equal(err.code, StatusCode.CANCELLED);
    return true;
  });
  const deadline = Date.now() + 5000;
  while (!observed.cancelled && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.ok(observed.cancelled, "backend must observe the stream reset");
  console.log("direction 2 cancel OK");

  // Backend dies mid-flight: later calls fail UNAVAILABLE,
  // they do not hang or succeed.
  backend.destroy();
  await assert.rejects(client.unary(new EchoRequest({ message: "hello" })), (err) => {
    assert.equal(err.code, StatusCode.UNAVAILABLE);
    return true;
  });
  console.log("direction 2 backend down OK");
});

test("rust proxy direction 2: backend unreachable at startup fails fast", { timeout: 60000 }, async (t) => {
  const closedPort = await freePort();
  const dcPort = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-listen", String(dcPort), "--http2-dial", `127.0.0.1:${closedPort}`,
  ]);
  t.after(() => stop(proxy));
  const code = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), 15000);
    proxy.on("close", (c) => { clearTimeout(timer); resolve(c); });
  });
  assert.notEqual(code, null, "proxy must exit when the backend connection fails");
  assert.notEqual(code, 0);
  console.log("direction 2 backend unreachable OK");
});

test("rust proxy direction 1 error path: dc server failure reaches the HTTP/2 client", { timeout: 180000 }, async (t) => {
  const listener = await directListener();
  t.after(() => listener.close());
  const serverEndpointPromise = acceptDirectEndpoint(listener);
  const server = new Server();
  server.addService(createEchoService({
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
      for await (const req of requests) yield new EchoResponse({ message: req.message, index: index++ });
    },
  }));
  serverEndpointPromise.then((endpoint) => server.serve(endpoint));
  t.after(async () => {
    const ep = await serverEndpointPromise;
    await ep.directEndpoint.close();
  });

  const port = await freePort();
  const proxy = start(`${ROOT}/rust/target/debug/examples/grpc_dc_proxy`, [
    "--dc-dial", listener.multiaddr(), "--http2", String(port),
  ]);
  t.after(() => stop(proxy));
  await waitFor(proxy, /ingress http2=/, "rust proxy ingress");

  const failed = await http2Call(port, "/echo.Echo/Unary",
    EchoRequest.encode(new EchoRequest({ message: "fail" })));
  assert.equal(failed.trailers["grpc-status"], "3");
  assert.ok(decodeURIComponent(failed.trailers["grpc-message"] ?? "").includes("asked to fail"),
    JSON.stringify(failed.trailers));
  console.log("direction 1 fail OK");
});

function sessionCall(port, path, payload, { delayMs = 0 } = {}) {
  const session = http2.connect(`http://127.0.0.1:${port}`);
  const done = new Promise((resolve, reject) => {
    const stream = session.request({
      ":path": path, ":method": "POST", ":scheme": "http",
      "content-type": "application/grpc", te: "trailers",
    });
    const parser = new LpmParser("identity");
    const messages = [];
    let trailers = null;
    const consume = () => {
      stream.on("data", (chunk) => messages.push(...parser.push(chunk)));
      stream.on("trailers", (tr) => (trailers = tr));
      stream.on("error", reject);
      stream.on("end", () => { session.close(); resolve({ messages, trailers }); });
    };
    stream.end(lpm(payload));
    if (delayMs > 0) setTimeout(consume, delayMs);
    else consume();
  });
  return done;
}

test("rust proxy stress: 4MB unary, 100 concurrent, slow consumer", { timeout: 300000 }, async (t) => {
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

  // 4 MB unary in each direction (16x the 256KB SCTP receive
  // window). This size used to stall: SACKs advertised a
  // constant a_rwnd regardless of gap-buffered bytes, and the
  // byte-wise GHASH throttled debug builds so far below window
  // rate that chunks aged into RTO recovery. Both are fixed
  // (per-TSN rwnd accounting in sctp.rs, u128 GHASH in
  // crypto.rs) with regression tests in webrtc/rust/tests.
  const big = "x".repeat(4 * 1024 * 1024);
  const t0 = Date.now();
  const r = await sessionCall(port, "/echo.Echo/Unary",
    EchoRequest.encode(new EchoRequest({ message: big })));
  assert.equal(r.trailers["grpc-status"], "0");
  const bigResp = EchoResponse.decode(r.messages[0]).message;
  assert.equal(bigResp.length, big.length + 6, "4MB echo length");
  assert.ok(bigResp.endsWith("xxxxxxxx"), "4MB echo tail");
  console.log(`stress large unary ok (${Date.now() - t0}ms)`);

  // 100 concurrent unary streams, one session each (proxy spawns
  // 100 DC streams over one endpoint).
  const jobs = Array.from({ length: 100 }, (_, i) =>
    sessionCall(port, "/echo.Echo/Unary",
      EchoRequest.encode(new EchoRequest({ message: `c${i}` })))
      .then((res) => {
        assert.equal(res.trailers["grpc-status"], "0");
        assert.equal(EchoResponse.decode(res.messages[0]).message, `echo: c${i}`);
      }));
  await Promise.all(jobs);
  console.log("stress 100 concurrent ok");

  // Slow consumer: server streams 3 x 512KB; the client waits
  // 800ms before draining. Flow control must hold, not drop.
  const fat = "y".repeat(512 * 1024);
  const s = await sessionCall(port, "/echo.Echo/ServerStream",
    EchoRequest.encode(new EchoRequest({ message: fat, count: 3 })), { delayMs: 800 });
  assert.equal(s.trailers["grpc-status"], "0");
  assert.equal(s.messages.length, 3);
  for (const m of s.messages) {
    assert.equal(EchoResponse.decode(m).message.length, fat.length);
  }
  console.log("stress slow consumer ok");
});
