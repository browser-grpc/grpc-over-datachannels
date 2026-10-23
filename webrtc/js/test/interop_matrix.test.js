// Native cross-stack interop matrix: Go, JS, and Rust
// hand-rolled WebRTC peers connect DIRECTLY to each other (no
// browser in the middle), in both offer/answer directions.
// Each stack is already proven against itself and against
// production browsers; this catches pairwise divergences
// (SDP handling, DTLS flights, SCTP parameters, stream reset)
// that neither oracle can see.
//
// All three peer_echo harnesses share one protocol: SDP is
// exchanged via files, the offerer opens channel "echo",
// stdin lines are sent and replies ("re:" + line) printed to
// stdout, and the "__close__" line resets the stream.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEBRTC = path.join(HERE, "..", "..");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function have(cmd) {
  return spawnSync("sh", ["-c", `command -v ${cmd}`], { stdio: "ignore" }).status === 0;
}

function buildGoHarness() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dc-interop-"));
  const bin = path.join(dir, "peer_echo_go");
  const res = spawnSync("go", ["build", "-o", bin, "./cmd/peer_echo"], {
    cwd: path.join(WEBRTC, "go"),
    encoding: "utf8",
  });
  if (res.status !== 0) throw new Error(`go build peer_echo: ${res.stderr}`);
  return bin;
}

function buildRustHarness() {
  const res = spawnSync("cargo", ["build", "--example", "peer_echo"], {
    cwd: path.join(WEBRTC, "rust"),
    encoding: "utf8",
  });
  if (res.status !== 0) throw new Error(`cargo build peer_echo: ${res.stderr}`);
  return path.join(WEBRTC, "rust", "target", "debug", "examples", "peer_echo");
}

const STACKS = {
  go: () => (have("go") ? [buildGoHarness()] : null),
  js: () => [process.execPath, path.join(WEBRTC, "js", "examples", "peer_echo.mjs")],
  rust: () => (have("cargo") ? [buildRustHarness()] : null),
};
const COMMANDS = {};
for (const [name, build] of Object.entries(STACKS)) {
  try {
    COMMANDS[name] = build();
  } catch {
    COMMANDS[name] = null;
  }
}

class Harness {
  constructor(cmd, mode, offerPath, answerPath) {
    this.stdoutLines = [];
    this.stderrText = "";
    this.waiters = [];
    this.proc = spawn(cmd[0], [...cmd.slice(1), mode, offerPath, answerPath], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc.stdout.setEncoding("utf8");
    this.proc.stderr.setEncoding("utf8");
    let buf = "";
    this.proc.stdout.on("data", (chunk) => {
      buf += chunk;
      let idx;
      while ((idx = buf.indexOf("\n")) >= 0) {
        this.stdoutLines.push(buf.slice(0, idx).replace(/\r$/, ""));
        buf = buf.slice(idx + 1);
      }
      this.pump();
    });
    this.proc.stderr.on("data", (chunk) => {
      this.stderrText += chunk;
      this.pump();
    });
    this.exited = new Promise((resolve) => this.proc.on("exit", resolve));
  }

  pump() {
    this.waiters = this.waiters.filter((w) => !w());
  }

  waitStderr(marker, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const deadline = setTimeout(
        () => reject(new Error(`waiting for ${marker}; stderr:\n${this.stderrText}`)),
        timeoutMs,
      );
      this.waiters.push(() => {
        if (this.stderrText.includes(marker)) {
          clearTimeout(deadline);
          resolve();
          return true;
        }
        return false;
      });
      this.pump();
    });
  }

  sendLine(line) {
    const countBefore = this.stdoutLines.length;
    this.proc.stdin.write(line + "\n");
    return new Promise((resolve, reject) => {
      const deadline = setTimeout(
        () => reject(new Error(`no reply to ${line}; stderr:\n${this.stderrText}`)),
        20000,
      );
      this.waiters.push(() => {
        if (this.stdoutLines.length > countBefore) {
          clearTimeout(deadline);
          resolve(this.stdoutLines[this.stdoutLines.length - 1]);
          return true;
        }
        return false;
      });
    });
  }

  kill() {
    this.proc.kill("SIGKILL");
  }
}

async function runPair(t, offererStack, answererStack) {
  const offererCmd = COMMANDS[offererStack];
  const answererCmd = COMMANDS[answererStack];
  if (!offererCmd || !answererCmd) {
    t.skip(`missing harness: offerer=${offererStack} answerer=${answererStack}`);
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dc-matrix-"));
  const offerPath = path.join(dir, "offer.sdp");
  const answerPath = path.join(dir, "answer.sdp");
  const answerer = new Harness(answererCmd, "answerer", offerPath, answerPath);
  const offerer = new Harness(offererCmd, "offerer", offerPath, answerPath);
  t.after(() => {
    offerer.kill();
    answerer.kill();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  await Promise.all([
    offerer.waitStderr("CONNECTED"),
    answerer.waitStderr("CONNECTED"),
  ]);
  await answerer.waitStderr("CHANNEL_OPEN");

  const tag = `${offererStack}-to-${answererStack}`;
  assert.equal(await offerer.sendLine(`hello-${tag}`), `re:hello-${tag}`);
  assert.equal(await offerer.sendLine("second message"), "re:second message");

  // Stream reset across stacks: both sides observe the close.
  assert.equal(await offerer.sendLine("__close__"), "closed");
  await offerer.waitStderr("CHANNEL_CLOSED_LOCAL", 15000);
  await answerer.waitStderr("CHANNEL_CLOSED", 15000);

  offerer.proc.stdin.end();
  const code = await Promise.race([
    offerer.exited,
    sleep(10000).then(() => "timeout"),
  ]);
  assert.equal(code, 0, `offerer exit=${code}; stderr:\n${offerer.stderrText}`);
}

for (const [offerer, answerer] of [
  ["go", "js"],
  ["js", "go"],
  ["go", "rust"],
  ["rust", "go"],
  ["js", "rust"],
  ["rust", "js"],
]) {
  test(`interop: ${offerer} offerer <-> ${answerer} answerer`, { timeout: 120000 }, (t) =>
    runPair(t, offerer, answerer),
  );
}
