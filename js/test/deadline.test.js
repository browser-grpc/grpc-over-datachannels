// Deadlines: grpc-timeout propagation + local enforcement.
// Options { timeout } (milliseconds) on every call shape; expiry
// aborts with RST and raises DEADLINE_EXCEEDED; the server ctx
// exposes deadline/timeRemaining.

import assert from "node:assert/strict";
import test from "node:test";

import {
  Channel,
  Server,
  StatusCode,
  encodeTimeout,
  memoryDataChannelPair,
  parseTimeout,
} from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function setup(seen) {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(
    createEchoService({
      async unary(req, ctx) {
        seen.ctx = ctx;
        await sleep(400);
        return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
      },
      async *serverStream(req) {
        for (let i = 0; i < Math.max(0, req.count); i++) {
          if (i) await sleep(300);
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
    }),
  );
  server.serve(b);
  return new EchoClient(new Channel(a));
}

test("grpc-timeout encode/parse", () => {
  assert.equal(parseTimeout(encodeTimeout(250)), 250);
  assert.equal(parseTimeout(encodeTimeout(90000)), 90000);
  assert.equal(parseTimeout("100m"), 100);
  assert.equal(parseTimeout("2S"), 2000);
  assert.equal(parseTimeout("1H"), 3600000);
  assert.equal(parseTimeout("10x"), null);
  assert.equal(parseTimeout(undefined), null);
});

test("unary deadline exceeded fast, ctx carries budget", async () => {
  const seen = {};
  const client = setup(seen);
  const start = Date.now();
  await assert.rejects(
    client.unary(new EchoRequest({ message: "hello" }), { timeout: 50 }),
    (e) => e.code === StatusCode.DEADLINE_EXCEEDED,
  );
  assert.ok(Date.now() - start < 350, "deadline fires before slow handler");
  const r = await client.clientStream([new EchoRequest({ message: "a" })], {
    timeout: 5000,
  });
  assert.equal(r.message, "a");
});

test("server stream deadline mid-stream", async () => {
  const seen = {};
  const client = setup(seen);
  const stream = await client.serverStream(
    new EchoRequest({ message: "tick", count: 5 }),
    { timeout: 150 },
  );
  const it = stream[Symbol.asyncIterator]();
  const first = await it.next();
  assert.equal(first.value.index, 0);
  await assert.rejects(it.next(), (e) => e.code === StatusCode.DEADLINE_EXCEEDED);
});

test("server ctx exposes deadline", async () => {
  const seen = {};
  const client = setup(seen);
  await assert.rejects(
    client.unary(new EchoRequest({ message: "hello" }), { timeout: 50 }),
    (e) => e.code === StatusCode.DEADLINE_EXCEEDED,
  );
  assert.ok(seen.ctx, "handler ran");
  assert.ok("grpc-timeout" in seen.ctx.metadata);
  assert.ok(typeof seen.ctx.deadline === "number");
  assert.ok(typeof seen.ctx.timeRemaining() === "number");
});
