import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server, StatusCode, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

function handlers() {
  return {
    async unary(req) {
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
      for await (const req of requests) {
        yield new EchoResponse({ message: req.message, index: index++ });
      }
    },
  };
}

function setup(clientStruct, serverStruct) {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.setStructCodec(serverStruct);
  server.addService(createEchoService(handlers()));
  server.serve(b);
  const channel = new Channel(a);
  channel.setStructCodec(clientStruct);
  return new EchoClient(channel);
}

const req = (message, count = 0) => new EchoRequest({ message, count });

test("struct codec: struct<->struct all shapes", async () => {
  const client = setup(true, true);

  const unary = await client.unary(req("hello"));
  assert.equal(unary.message, "echo: hello");

  const got = [];
  for await (const resp of await client.serverStream(req("tick", 3))) got.push(resp);
  assert.equal(got.length, 3);

  const joined = await client.clientStream([req("a"), req("b")]);
  assert.equal(joined.message, "a+b");

  const echoed = [];
  for await (const resp of await client.bidi([req("x"), req("y")])) echoed.push(resp.message);
  assert.deepEqual(echoed, ["x", "y"]);
});

test("struct codec: wire bytes carry DCS1 magic and roundtrip", () => {
  const bytes = EchoRequest.encodeStruct(req("hello"));
  assert.ok(bytes.length > 4);
  assert.deepEqual([...bytes.subarray(0, 4)], [0x44, 0x43, 0x53, 0x31]);
  const back = EchoRequest.decodeStruct(bytes);
  assert.equal(back.message, "hello");
});

test("struct codec: struct client vs protobuf server fails UNIMPLEMENTED", async () => {
  const client = setup(true, false);
  await assert.rejects(client.unary(req("hello")), (e) => e.code === StatusCode.UNIMPLEMENTED);
});

test("struct codec: plain client vs struct server succeeds", async () => {
  const client = setup(false, true);
  const resp = await client.unary(req("hello"));
  assert.equal(resp.message, "echo: hello");
});
