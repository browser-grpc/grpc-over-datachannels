// Cross-language interop: the same grpc-dc frames, Rust on one side and
// JavaScript on the other, bridged over a child process's stdio.
// The 4-byte length prefix exists only to frame messages on stdio; each
// framed unit is exactly one DataChannel message (one grpc-dc frame).

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";

import { Channel, Server, StatusCode, StatusError } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

const RUST_DIR = new URL("../../rust/", import.meta.url).pathname;

/** Wrap a child process's stdio as a data-channel-shaped object. */
class ChildChannel {
  #buffer = new Uint8Array(0);
  #listeners = new Map();
  readyState = "open";
  bufferedAmount = 0;
  binaryType = "arraybuffer";

  constructor(proc) {
    this.proc = proc;
    proc.stdout.on("data", (chunk) => {
      const merged = new Uint8Array(this.#buffer.length + chunk.length);
      merged.set(this.#buffer);
      merged.set(chunk, this.#buffer.length);
      this.#buffer = merged;
      for (;;) {
        if (this.#buffer.length < 4) return;
        const len = new DataView(this.#buffer.buffer, this.#buffer.byteOffset).getUint32(0, false);
        if (this.#buffer.length < 4 + len) return;
        const frame = this.#buffer.slice(4, 4 + len);
        this.#buffer = this.#buffer.slice(4 + len);
        this.#emit("message", { data: frame });
      }
    });
  }

  addEventListener(type, fn) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, []);
    this.#listeners.get(type).push(fn);
  }

  removeEventListener(type, fn) {
    const list = this.#listeners.get(type) ?? [];
    this.#listeners.set(type, list.filter((f) => f !== fn));
  }

  #emit(type, event) {
    for (const fn of [...(this.#listeners.get(type) ?? [])]) fn(event);
  }

  send(data) {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
    const header = new Uint8Array(4);
    new DataView(header.buffer).setUint32(0, bytes.length, false);
    this.proc.stdin.write(header);
    this.proc.stdin.write(bytes);
  }

  close() {
    this.readyState = "closed";
    this.proc.stdin.end();
    this.proc.kill();
  }
}

function spawnRust(example) {
  const proc = spawn("cargo", ["run", "--quiet", "--example", example], {
    cwd: RUST_DIR,
    stdio: ["pipe", "pipe", "pipe"],
  });
  proc.stderrText = "";
  proc.stderr.on("data", (chunk) => {
    proc.stderrText += chunk.toString("utf8");
  });
  return proc;
}

async function waitExit(proc, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      proc.kill();
      reject(new Error("rust client did not exit in time"));
    }, timeoutMs);
    proc.on("exit", (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
}

test("JS client calls the Rust server (all four shapes)", { timeout: 180000 }, async () => {
  const proc = spawnRust("echo_server_stdio");
  const dc = new ChildChannel(proc);
  try {
    const client = new EchoClient(new Channel(dc));
    const req = (message, count = 0) => new EchoRequest({ message, count });

    const unary = await client.unary(req("hello"));
    assert.equal(unary.message, "echo: hello");

    const ticks = [];
    for await (const resp of await client.serverStream(req("tick", 3))) {
      ticks.push(`${resp.message}#${resp.index}`);
    }
    assert.deepEqual(ticks, ["tick#0", "tick#1", "tick#2"]);

    async function* abc() {
      yield req("a");
      yield req("b");
      yield req("c");
    }
    const joined = await client.clientStream(abc());
    assert.equal(joined.message, "a+b+c");

    async function* xy() {
      yield req("x");
      yield req("y");
    }
    const echoed = [];
    for await (const resp of await client.bidi(xy())) echoed.push(resp.message);
    assert.deepEqual(echoed, ["x", "y"]);

    await assert.rejects(
      client.unary(req("fail")),
      (e) => e.code === StatusCode.INVALID_ARGUMENT,
    );
  } finally {
    dc.close();
  }
});

test("Rust client calls the JS server (all four shapes)", { timeout: 180000 }, async () => {
  const proc = spawnRust("echo_client_stdio");
  const dc = new ChildChannel(proc);

  // Frames travel on stdout; the Rust client reports results on stderr.
  const server = new Server();
  server.addService(
    createEchoService({
      async unary(req, ctx) {
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
        for await (const r of requests) parts.push(r.message);
        return new EchoResponse({ message: parts.join("+"), index: parts.length });
      },
      async *bidi(requests) {
        let index = 0;
        for await (const r of requests) {
          yield new EchoResponse({ message: r.message, index: index++ });
        }
      },
    }),
  );
  server.serve(dc);

  const code = await waitExit(proc);
  assert.equal(code, 0, proc.stderrText);
  assert.match(proc.stderrText, /unary=echo: hello/);
  assert.match(proc.stderrText, /server_stream=tick#0,tick#1,tick#2/);
  assert.match(proc.stderrText, /client_stream=a\+b\+c/);
  assert.match(proc.stderrText, /bidi=x,y/);
  dc.proc.kill();
});
