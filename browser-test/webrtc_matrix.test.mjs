// WebRTC-stack interop matrix: the three reimplemented
// WebRTC stacks (Go, JS, Rust — see SPEC-WEBRTC.md) paired
// over real ICE/DTLS/DataChannels, no browser and no loopback
// byte pump. gRPC Echo cells pair the Go and JS stacks in
// both directions and against themselves (file-exchanged SDP
// via the existing grpc_webrtc_client/server harnesses); the
// Rust stack, which has no gRPC-over-WebRTC harness binary,
// pairs at the DataChannel level via the mirrored peer_echo
// line-echo harnesses (Go and Rust) and the JS Peer. A final
// block pairs PeerMux against PeerMux across stacks (two
// pairs over one socket per side), proving the DTLS
// connection-id (RFC 9146) demux wire profile agrees across
// stacks. Run via `make test-webrtc-matrix`.

import assert from "node:assert/strict";
import { execSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { Peer } from "../webrtc/js/peer.js";
import { PeerMux } from "../webrtc/js/mux.js";
import { Channel, Server, StatusError } from "../js/index.js";
import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";
import { EchoClient, createEchoService } from "../js/examples/echo_grpc_dc.js";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const GO = process.env.GO || "go";
const CARGO = process.env.CARGO || "cargo";

const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") throw new StatusError(3, "asked to fail");
    if (req.delayMs > 0) await new Promise((resolve) => setTimeout(resolve, req.delayMs));
    const marker = ctx?.metadata?.["x-echo"];
    const suffix = marker ? ` [${marker}]` : "";
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

function build(cmd, cwd) {
  execSync(cmd, { cwd: join(ROOT, cwd), stdio: "inherit", shell: "/bin/bash" });
}

function waitForFile(path, timeoutMs = 60000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      try {
        const text = readFileSync(path, "utf8");
        if (text.trim().length > 0) return resolve(text);
      } catch {}
      if (Date.now() - start > timeoutMs) return reject(new Error(`timeout waiting for ${path}`));
      setTimeout(tick, 25);
    };
    tick();
  });
}

function spawnProc(cmd, args, cwd) {
  const proc = spawn(cmd, args, { cwd: join(ROOT, cwd) });
  let stderr = "";
  proc.stderr.on("data", (d) => { stderr += d; });
  proc.getStderr = () => stderr;
  return proc;
}

function waitExit(proc, timeoutMs = 120000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error(`process timeout: ${proc.getStderr()}`));
    }, timeoutMs);
    proc.on("exit", (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
}

async function runJsClient(dc) {
  if (dc.readyState !== "open") {
    await new Promise((resolve) => dc.addEventListener("open", resolve, { once: true }));
  }
  const client = new EchoClient(new Channel(dc));
  const req = (message, count = 0, delayMs = 0) => new EchoRequest({ message, count, delayMs });
  const unary = await client.unary(req("hello"));
  assert.equal(unary.message, "echo: hello");
  const ticks = [];
  for await (const resp of await client.serverStream(req("tick", 3))) ticks.push(resp.index);
  assert.deepEqual(ticks, [0, 1, 2]);
  async function* ab() { yield req("a"); yield req("b"); }
  const joined = await client.clientStream(ab());
  assert.equal(joined.message, "a+b");
  async function* xy() { yield req("x"); yield req("y"); }
  const echoed = [];
  for await (const resp of await client.bidi(xy())) echoed.push(resp.message);
  assert.deepEqual(echoed, ["x", "y"]);

  let errorCode = 0;
  try {
    await client.unary(req("fail"));
  } catch (e) {
    errorCode = e.code;
  }
  assert.equal(errorCode, 3);

  const md = await client.unary(req("hello"), { metadata: { "x-echo": "meta" } });
  assert.equal(md.message, "echo: hello [meta]");

  let deadlineCode = 0;
  try {
    await client.unary(req("slow", 0, 400), { timeout: 50 });
  } catch (e) {
    deadlineCode = e.code;
  }
  assert.equal(deadlineCode, 4);
}

function serveJs(endpoint) {
  const grpcServer = new Server();
  grpcServer.addService(createEchoService(handlers));
  endpoint.onchannel = (channel) => grpcServer.serve(channel);
}

// --- builds ---------------------------------------------------------------
build(`${GO} build -o build/grpc_webrtc_client ./cmd/grpc_webrtc_client && ${GO} build -o build/grpc_webrtc_server ./cmd/grpc_webrtc_server`, "go");
build(`${GO} build -o ${join(ROOT, "go/build/peer_echo")} ./cmd/peer_echo`, "webrtc/go");
build(`${CARGO} build --example peer_echo`, "webrtc/rust");

const GO_CLIENT = join(ROOT, "go/build/grpc_webrtc_client");
const GO_SERVER = join(ROOT, "go/build/grpc_webrtc_server");
const GO_ECHO = join(ROOT, "go/build/peer_echo");
const RUST_ECHO = join(ROOT, "webrtc/rust/target/debug/examples/peer_echo");
for (const bin of [GO_CLIENT, GO_SERVER, GO_ECHO, RUST_ECHO]) {
  assert.ok(existsSync(bin), `missing harness binary ${bin}`);
}

const cells = [];
let attempted = 0;
async function cell(name, fn) {
  attempted++;
  try {
    await fn();
    cells.push(name);
    console.log(`ok ${name}`);
  } catch (err) {
    console.log(`FAIL ${name}: ${err.message}`);
    process.exitCode = 1;
  }
}

// --- gRPC cells -------------------------------------------------------------
await cell("grpc go-client -> go-server", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-"));
  const base = join(dir, "sig");
  const server = spawnProc(GO_SERVER, [base], ".");
  const client = spawnProc(GO_CLIENT, [base], ".");
  const code = await waitExit(client);
  server.kill("SIGKILL");
  assert.equal(code, 0, client.getStderr());
  assert.match(client.getStderr(), /unary=echo: hello/);
  assert.match(client.getStderr(), /metadata=echo: hello \[meta\]/);
  assert.match(client.getStderr(), /deadline=4/);
});

await cell("grpc go-client -> js-server", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-"));
  const base = join(dir, "sig");
  const client = spawnProc(GO_CLIENT, [base], ".");
  const answerer = await Peer.create();
  try {
    const offer = await waitForFile(`${base}.offer`);
    const answer = answerer.handleOffer(offer);
    writeFileSync(`${base}.answer`, answer);
    const endpoint = await answerer.connect();
    serveJs(endpoint);
    const code = await waitExit(client);
    assert.equal(code, 0, client.getStderr());
    assert.match(client.getStderr(), /unary=echo: hello/);
    assert.match(client.getStderr(), /metadata=echo: hello \[meta\]/);
    assert.match(client.getStderr(), /deadline=4/);
  } finally {
    client.kill("SIGKILL");
    await answerer.close();
  }
});

await cell("grpc js-client -> go-server", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-"));
  const base = join(dir, "sig");
  const server = spawnProc(GO_SERVER, [base], ".");
  const offerer = await Peer.create();
  try {
    writeFileSync(`${base}.offer`, offerer.createOffer());
    const answer = await waitForFile(`${base}.answer`);
    offerer.handleAnswer(answer);
    const endpoint = await offerer.connect();
    const dc = endpoint.openChannel({ label: "grpc" });
    await runJsClient(dc);
  } finally {
    server.kill("SIGKILL");
    await offerer.close();
  }
});

await cell("grpc js-client -> js-server", async () => {
  const offerer = await Peer.create();
  const answerer = await Peer.create();
  try {
    const answer = answerer.handleOffer(offerer.createOffer());
    offerer.handleAnswer(answer);
    const [clientEp, serverEp] = await Promise.all([offerer.connect(), answerer.connect()]);
    serveJs(serverEp);
    const dc = clientEp.openChannel({ label: "grpc" });
    await runJsClient(dc);
  } finally {
    await offerer.close();
    await answerer.close();
  }
});

// --- DataChannel echo cells (peer_echo, file SDP) ---------------------------
function echoCell(name, offererCmd, answererCmd) {
  return cell(name, async () => {
    const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-"));
    const offer = join(dir, "offer");
    const answer = join(dir, "answer");
    const answerer = spawn(answererCmd[0], [...answererCmd.slice(1), "answerer", offer, answer], { cwd: ROOT });
    const offerer = spawn(offererCmd[0], [...offererCmd.slice(1), "offerer", offer, answer], { cwd: ROOT });
    let out = "";
    offerer.stdout.on("data", (d) => { out += d; });
    offerer.stderr.on("data", () => {});
    answerer.stderr.on("data", () => {});
    offerer.stdin.write("hello matrix\n");
    const start = Date.now();
    while (!out.includes("hello matrix")) {
      if (Date.now() - start > 60000) throw new Error(`echo timeout, got: ${out}`);
      await new Promise((r) => setTimeout(r, 50));
    }
    offerer.kill("SIGKILL");
    answerer.kill("SIGKILL");
  });
}

await echoCell("dc go-offerer -> rust-answerer", [GO_ECHO], [RUST_ECHO]);
await echoCell("dc rust-offerer -> go-answerer", [RUST_ECHO], [GO_ECHO]);

await cell("dc js-offerer -> rust-answerer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-"));
  const offerPath = join(dir, "offer");
  const answerPath = join(dir, "answer");
  const answerer = spawn(RUST_ECHO, ["answerer", offerPath, answerPath], { cwd: ROOT });
  answerer.stderr.on("data", () => {});
  const offerer = await Peer.create();
  try {
    writeFileSync(offerPath, offerer.createOffer());
    const answer = await waitForFile(answerPath);
    offerer.handleAnswer(answer);
    const endpoint = await offerer.connect();
    const dc = endpoint.openChannel({ label: "echo" });
    if (dc.readyState !== "open") {
      await new Promise((resolve) => dc.addEventListener("open", resolve, { once: true }));
    }
    const echoed = new Promise((resolve) => {
      dc.addEventListener("message", (event) => resolve(new TextDecoder().decode(event.data)));
    });
    dc.send("hello matrix");
    // The Rust echo harness replies with an "re:" prefix.
    assert.equal(await echoed, "re:hello matrix");
  } finally {
    answerer.kill("SIGKILL");
    await offerer.close();
  }
});

await cell("dc rust-offerer -> js-answerer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-"));
  const offerPath = join(dir, "offer");
  const answerPath = join(dir, "answer");
  const offerer = spawn(RUST_ECHO, ["offerer", offerPath, answerPath], { cwd: ROOT });
  let out = "";
  offerer.stdout.on("data", (d) => { out += d; });
  offerer.stderr.on("data", () => {});
  const answerer = await Peer.create();
  try {
    const offer = await waitForFile(offerPath);
    writeFileSync(answerPath, answerer.handleOffer(offer));
    const endpoint = await answerer.connect();
    endpoint.onchannel = (dc) => {
      dc.addEventListener("message", (event) => dc.send(event.data));
    };
    offerer.stdin.write("hello matrix\n");
    const start = Date.now();
    while (!out.includes("hello matrix")) {
      if (Date.now() - start > 60000) throw new Error(`echo timeout, got: ${out}`);
      await new Promise((r) => setTimeout(r, 50));
    }
  } finally {
    offerer.kill("SIGKILL");
    await answerer.close();
  }
});

// --- Mux-to-mux cells (PeerMux both sides, DTLS CID demux) ------------------
// Two pairs share one mux socket per side, so both directions
// present a single source address: only the DcPairHint (first
// flight) and connection ids (RFC 9146) can demux. The native
// stacks run the peer_echo mux modes; JS runs in-process.
// This is the cross-stack proof that the CID wire profile
// (record layout + AAD) agrees byte-for-byte across stacks.
function waitForMuxOk(proc, timeoutMs = 90000) {
  return new Promise((resolve, reject) => {
    let out = "";
    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      reject(new Error(`mux offerer timeout, got: ${out}`));
    }, timeoutMs);
    proc.stdout.on("data", (d) => {
      out += d;
      if (out.includes("MUX_OK")) {
        clearTimeout(timer);
        resolve(out);
      }
    });
  });
}

function assertMuxOut(out) {
  assert.ok(out.includes("pair0: re:hello-from-pair-0"), out);
  assert.ok(out.includes("pair1: re:hello-from-pair-1"), out);
}

function muxCellNative(name, offererCmd, answererCmd) {
  return cell(name, async () => {
    const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-mux-"));
    const answerer = spawn(answererCmd[0], [...answererCmd.slice(1), "mux-answerer", dir], { cwd: ROOT });
    const offerer = spawn(offererCmd[0], [...offererCmd.slice(1), "mux-offerer", dir], { cwd: ROOT });
    answerer.stderr.on("data", () => {});
    offerer.stderr.on("data", () => {});
    try {
      assertMuxOut(await waitForMuxOk(offerer));
    } finally {
      offerer.kill("SIGKILL");
      answerer.kill("SIGKILL");
    }
  });
}

async function jsMuxOfferer(dir) {
  const mux = await PeerMux.bind({ address: "127.0.0.1", port: 0 });
  const peers = [];
  for (let i = 0; i < 2; i++) {
    const peer = await mux.createPeer({ localIps: ["127.0.0.1"] });
    writeFileSync(join(dir, `offer${i}`), peer.createOffer());
    peers.push(peer);
  }
  try {
    const endpoints = await Promise.all(
      peers.map(async (peer, i) => {
        peer.handleAnswer(await waitForFile(join(dir, `answer${i}`)));
        return peer.connect();
      }),
    );
    await Promise.all(
      endpoints.map(async (endpoint, i) => {
        const channel = endpoint.openChannel({ label: "echo" });
        const reply = new Promise((resolve) => {
          channel.onmessage = (event) =>
            resolve(Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data));
        });
        channel.send(Buffer.from(`hello-from-pair-${i}`));
        assert.equal(await reply, `re:hello-from-pair-${i}`);
      }),
    );
  } finally {
    for (const peer of peers) await peer.close();
    mux.close();
  }
}

// Sets up a JS mux answerer (echo with "re:") and resolves
// to a close function once both peers are connected and
// serving; echo runs on socket events in the background.
async function jsMuxAnswerer(dir) {
  const mux = await PeerMux.bind({ address: "127.0.0.1", port: 0 });
  const peers = [];
  const endpoints = await Promise.all(
    [0, 1].map(async (i) => {
      const peer = await mux.createPeer({ localIps: ["127.0.0.1"] });
      peers.push(peer);
      const answer = peer.handleOffer(await waitForFile(join(dir, `offer${i}`)));
      writeFileSync(join(dir, `answer${i}`), answer);
      return peer.connect();
    }),
  );
  for (const endpoint of endpoints) {
    endpoint.onchannel = (channel) => {
      channel.onmessage = (event) => {
        const text = Buffer.isBuffer(event.data) ? event.data.toString() : String(event.data);
        channel.send(Buffer.from(`re:${text}`));
      };
    };
  }
  return async () => {
    for (const peer of peers) await peer.close();
    mux.close();
  };
}

await muxCellNative("mux rust-offerer -> go-answerer", [RUST_ECHO], [GO_ECHO]);
await muxCellNative("mux go-offerer -> rust-answerer", [GO_ECHO], [RUST_ECHO]);

await cell("mux js-offerer -> rust-answerer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-mux-"));
  const answerer = spawn(RUST_ECHO, ["mux-answerer", dir], { cwd: ROOT });
  answerer.stderr.on("data", () => {});
  try {
    await jsMuxOfferer(dir);
  } finally {
    answerer.kill("SIGKILL");
  }
});

await cell("mux js-offerer -> go-answerer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-mux-"));
  const answerer = spawn(GO_ECHO, ["mux-answerer", dir], { cwd: ROOT });
  answerer.stderr.on("data", () => {});
  try {
    await jsMuxOfferer(dir);
  } finally {
    answerer.kill("SIGKILL");
  }
});

await cell("mux rust-offerer -> js-answerer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-mux-"));
  const offerer = spawn(RUST_ECHO, ["mux-offerer", dir], { cwd: ROOT });
  offerer.stderr.on("data", () => {});
  const closeAnswerer = await jsMuxAnswerer(dir);
  try {
    assertMuxOut(await waitForMuxOk(offerer));
  } finally {
    offerer.kill("SIGKILL");
    await closeAnswerer();
  }
});

await cell("mux go-offerer -> js-answerer", async () => {
  const dir = mkdtempSync(join(tmpdir(), "webrtc-matrix-mux-"));
  const offerer = spawn(GO_ECHO, ["mux-offerer", dir], { cwd: ROOT });
  offerer.stderr.on("data", () => {});
  const closeAnswerer = await jsMuxAnswerer(dir);
  try {
    assertMuxOut(await waitForMuxOk(offerer));
  } finally {
    offerer.kill("SIGKILL");
    await closeAnswerer();
  }
});

console.log(`webrtc matrix: ${cells.length}/${attempted} cells passed`);
if (process.exitCode) process.exit(1);
