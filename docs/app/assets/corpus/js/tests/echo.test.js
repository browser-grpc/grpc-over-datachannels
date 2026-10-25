import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  Channel,
  Server,
  StatusCode,
  StatusError,
  decodeFrame,
  encodeFrame,
  fromHex,
  memoryDataChannelPair,
  toHex,
} from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

const vectors = JSON.parse(
  readFileSync(new URL("../../fixtures/vectors.json", import.meta.url), "utf8"),
);

test("golden frame vectors (shared with Racket and Rust)", () => {
  for (const frame of vectors.frames) {
    const payload = frame.payload_utf8
      ? new TextEncoder().encode(frame.payload_utf8)
      : fromHex(frame.payload_hex);
    const encoded = encodeFrame(frame.type, frame.stream, payload);
    assert.equal(toHex(encoded), frame.hex, `encode ${frame.name}`);
    const decoded = decodeFrame(fromHex(frame.hex));
    assert.equal(decoded.type, frame.type);
    assert.equal(decoded.streamId, frame.stream);
    assert.deepEqual(decoded.payload, payload);
  }
  assert.throws(() => decodeFrame(new Uint8Array([1, 2])), (e) => e.code === StatusCode.INVALID_ARGUMENT);
});

test("protobuf golden bytes (shared with Racket and Rust)", () => {
  const encoded = EchoRequest.encode(new EchoRequest({ message: "hi", count: 2 }));
  assert.equal(toHex(encoded), vectors.protobuf.echo_request.hex);
  const decoded = EchoRequest.decode(fromHex(vectors.protobuf.echo_request.hex));
  assert.equal(decoded.message, "hi");
  assert.equal(decoded.count, 2);
  assert.equal(decoded.delayMs, 0);
});

function handlers() {
  return {
    async unary(req, ctx) {
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
      const suffix = ctx.metadata["x-echo"] ? ` [${ctx.metadata["x-echo"]}]` : "";
      return new EchoResponse({ message: `echo: ${req.message}${suffix}`, index: 0 });
    },
    async *serverStream(req) {
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
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
}

function setup() {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers()));
  server.serve(b);
  return new EchoClient(new Channel(a));
}

const req = (message, count = 0) => new EchoRequest({ message, count });

test("unary round trip", async () => {
  const client = setup();
  const resp = await client.unary(req("hello"));
  assert.equal(resp.message, "echo: hello");
});

test("server streaming", async () => {
  const client = setup();
  const got = [];
  for await (const resp of await client.serverStream(req("tick", 3))) got.push(resp);
  assert.equal(got.length, 3);
  assert.equal(got[2].index, 2);
  assert.ok(got.every((r) => r.message === "tick"));
});

test("breaking a server stream cancels it server-side", async () => {
  let produced = 0;
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService({
    ...handlers(),
    async *serverStream(req) {
      for (let i = 0; i < req.count; i++) {
        produced++;
        yield new EchoResponse({ message: "tick", index: i });
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    },
  }));
  server.serve(b);
  const client = new EchoClient(new Channel(a));
  let seen = 0;
  for await (const _resp of await client.serverStream(req("tick", 1000))) {
    if (++seen === 2) break;
  }
  assert.equal(seen, 2);
  // The break must RST the call: production stops instead of
  // the handler streaming into the void.
  await new Promise((resolve) => setTimeout(resolve, 100));
  const settled = produced;
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(produced, settled);
  assert.ok(settled < 100, `server kept producing (${settled})`);
});

test("client streaming", async () => {
  const client = setup();
  async function* reqs() {
    yield req("a");
    yield req("b");
    yield req("c");
  }
  const resp = await client.clientStream(reqs());
  assert.equal(resp.message, "a+b+c");
  assert.equal(resp.index, 3);
});

test("bidi streaming", async () => {
  const client = setup();
  async function* reqs() {
    yield req("x");
    yield req("y");
    yield req("z");
  }
  const got = [];
  for await (const resp of await client.bidi(reqs())) got.push(resp.message);
  assert.deepEqual(got, ["x", "y", "z"]);
});

test("handler error propagates as status", async () => {
  const client = setup();
  await assert.rejects(client.unary(req("fail")), (e) => {
    assert.equal(e.code, StatusCode.INVALID_ARGUMENT);
    assert.match(e.message, /asked to fail/);
    return true;
  });
  await assert.rejects(
    (async () => {
      for await (const _ of await client.serverStream(req("fail", 1))) {
        // unreachable: first read must throw
      }
    })(),
    (e) => e.code === StatusCode.INVALID_ARGUMENT,
  );
});

test("unknown method is UNIMPLEMENTED", async () => {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers()));
  server.serve(b);
  const channel = new Channel(a);
  await assert.rejects(
    channel.unary("/echo.Echo/Nope", req("hi"), EchoRequest, EchoResponse),
    (e) => e.code === StatusCode.UNIMPLEMENTED,
  );
});

test("concurrent unary calls multiplex over one channel", async () => {
  const client = setup();
  const results = await Promise.all(
    Array.from({ length: 16 }, (_, i) => client.unary(req(`m${i}`))),
  );
  results.forEach((resp, i) => assert.equal(resp.message, `echo: m${i}`));
});
