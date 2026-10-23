// DataChannel (DTLS+SCTP+DCEP) cross-tests between the JS and Rust
// stacks, driven through the dc_echo harnesses over UDP loopback.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";

const ROOT = new URL("../../..", import.meta.url).pathname;
const RUST_BIN = `${ROOT}webrtc/rust/target/debug/examples/dc_echo`;
const JS_ECHO = `${ROOT}webrtc/js/examples/dc_echo.mjs`;

// Spawn an in-repo echo server on an ephemeral port and read
// the allocated port from its LISTENING line: no
// probe-close-rebind race, and no fixed ports.
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
  const { proc: server, port } = await startEchoServer(RUST_BIN, []);
  try {
    const client = await runClient("node", [JS_ECHO, "client", String(port)], "hello-dc\n");
    assert.equal(client.code, 0, client.stderr);
    assert.equal(client.stdout.trim(), "re:hello-dc");
  } finally {
    server.kill();
  }
});

test("Rust datachannel client echoes via JS server", { timeout: 60000 }, async () => {
  const { proc: server, port } = await startEchoServer("node", [JS_ECHO]);
  try {
    const client = await runClient(RUST_BIN, ["client", String(port)], "hello-dc\n");
    assert.equal(client.code, 0, client.stderr);
    assert.equal(client.stdout.trim(), "re:hello-dc");
  } finally {
    server.kill();
  }
});
