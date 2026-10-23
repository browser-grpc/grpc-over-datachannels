// DTLS cross-tests: JS against the Rust stack (both roles, driven via
// the dtls_echo harnesses) and against OpenSSL when the CLI is present.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import dgram from "node:dgram";
import test from "node:test";

const ROOT = new URL("../../..", import.meta.url).pathname;
const RUST_BIN = `${ROOT}webrtc/rust/target/debug/examples/dtls_echo`;
const JS_ECHO = `${ROOT}webrtc/js/examples/dtls_echo.mjs`;

// Probe-close free port, only for external daemons that take
// a numeric port argument (openssl s_server below): bind(0),
// read the allocated port, close, and let the daemon rebind
// it. The race is unavoidable there, so the caller retries
// startup on failure. In-repo harnesses bind ephemeral
// themselves and report their allocated port (startEchoServer).
async function freePort() {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const { port } = socket.address();
  socket.close();
  return port;
}

// Spawn an in-repo echo server on an ephemeral port and read
// the allocated port from its LISTENING line.
function startEchoServer(command, args) {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, [...args, "server", "0"], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`no LISTENING from ${command}; stderr=${stderr}`));
    }, 30000);
    proc.stderr.on("data", (d) => {
      stderr += d;
      const m = stderr.match(/LISTENING (\d+)/);
      if (m) {
        clearTimeout(timer);
        resolve({ proc, port: Number(m[1]) });
      }
    });
    proc.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`${command} exited ${code} before LISTENING; stderr=${stderr}`));
    });
  });
}

function runEcho(command, args, input, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const proc = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error(`timeout; stdout=${stdout} stderr=${stderr}`));
    }, timeoutMs);
    proc.on("exit", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
    proc.stdin.end(input);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("JS client calls Rust DTLS server", { timeout: 60000 }, async () => {
  const { proc: server, port } = await startEchoServer(RUST_BIN, []);
  try {
    const client = await runEcho("node", [JS_ECHO, "client", String(port)], "hello-js\n");
    assert.equal(client.code, 0, client.stderr);
    assert.match(client.stderr, /HANDSHAKE_OK/);
    assert.equal(client.stdout.trim(), "echo:hello-js");
  } finally {
    server.kill();
  }
});

test("Rust client calls JS DTLS server", { timeout: 60000 }, async () => {
  const { proc: server, port } = await startEchoServer("node", [JS_ECHO]);
  try {
    const client = await runEcho(RUST_BIN, ["client", String(port)], "hello-rust\n");
    assert.equal(client.code, 0, client.stderr);
    assert.equal(client.stdout.trim(), "echo:hello-rust");
  } finally {
    server.kill();
  }
});

test("JS client calls OpenSSL s_server", { timeout: 60000 }, async (t) => {
  if (spawnSync("openssl", ["version"]).status !== 0) {
    t.skip("openssl CLI not available");
    return;
  }
  const gen = spawnSync("openssl", [
    "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
    "-keyout", "/tmp/dc-webrtc-key.pem", "-out", "/tmp/dc-webrtc-cert.pem",
    "-days", "1", "-nodes", "-subj", "/CN=openssl-dtls",
  ]);
  assert.equal(gen.status, 0);
  // s_server takes a numeric port (probe-close, see freePort):
  // verify it survived startup, retrying on a fresh port when
  // it did not (e.g. the probed port was taken before bind).
  let server = null;
  let port = 0;
  for (let attempt = 0; attempt < 3 && !server; attempt++) {
    port = await freePort();
    const candidate = spawn(
      "openssl",
      ["s_server", "-accept", String(port), "-dtls1_2", "-cert", "/tmp/dc-webrtc-cert.pem", "-key", "/tmp/dc-webrtc-key.pem"],
      { stdio: ["pipe", "pipe", "ignore"] },
    );
    await sleep(500);
    if (candidate.exitCode === null) server = candidate;
  }
  assert.ok(server, "openssl s_server did not survive startup after 3 attempts");
  try {
    const client = spawn("node", [JS_ECHO, "client", String(port)], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    client.stdout.on("data", (d) => (stdout += d));
    client.stderr.on("data", (d) => (stderr += d));
    client.stdin.write("ping-js\n");
    await sleep(1000);
    server.stdin.write("from-openssl\n");
    client.stdin.end();
    const code = await new Promise((resolve) => client.on("exit", resolve));
    assert.equal(code, 0, stderr);
    assert.match(stderr, /HANDSHAKE_OK/);
    assert.equal(stdout.trim(), "from-openssl");
  } finally {
    server.kill();
  }
});
