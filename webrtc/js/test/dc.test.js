// DataChannel (DTLS+SCTP+DCEP) cross-tests between the JS and Rust
// stacks, driven through the dc_echo harnesses over UDP loopback.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import dgram from "node:dgram";
import test from "node:test";

const ROOT = new URL("../../..", import.meta.url).pathname;
const RUST_BIN = `${ROOT}webrtc/rust/target/debug/examples/dc_echo`;
const JS_ECHO = `${ROOT}webrtc/js/examples/dc_echo.mjs`;

async function freePort() {
  const socket = dgram.createSocket("udp4");
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  const { port } = socket.address();
  socket.close();
  return port;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function runClient(command, args, input, timeoutMs = 30000) {
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

test("JS datachannel client echoes via Rust server", { timeout: 60000 }, async () => {
  const port = await freePort();
  const server = spawn(RUST_BIN, ["server", String(port)], { stdio: ["ignore", "ignore", "ignore"] });
  try {
    await sleep(300);
    const client = await runClient("node", [JS_ECHO, "client", String(port)], "hello-dc\n");
    assert.equal(client.code, 0, client.stderr);
    assert.equal(client.stdout.trim(), "re:hello-dc");
  } finally {
    server.kill();
  }
});

test("Rust datachannel client echoes via JS server", { timeout: 60000 }, async () => {
  const port = await freePort();
  const server = spawn("node", [JS_ECHO, "server", String(port)], {
    stdio: ["ignore", "ignore", "ignore"],
  });
  try {
    await sleep(500);
    const client = await runClient(RUST_BIN, ["client", String(port)], "hello-dc\n");
    assert.equal(client.code, 0, client.stderr);
    assert.equal(client.stdout.trim(), "re:hello-dc");
  } finally {
    server.kill();
  }
});
