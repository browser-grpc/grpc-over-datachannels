// Runtime registration (JS): addService/removeService after
// serve take effect on the next call; registeredServices
// lists what is live.

import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server, StatusCode, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

const handlers = {
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

test("register and unregister after serve", async () => {
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.serve(b);
  const client = new EchoClient(new Channel(a));
  const req = () => new EchoRequest({ message: "hi" });

  await assert.rejects(client.unary(req()), (e) => e.code === StatusCode.UNIMPLEMENTED);
  server.addService(createEchoService(handlers));
  assert.deepEqual(server.registeredServices(), ["echo.Echo"]);
  const resp = await client.unary(req());
  assert.equal(resp.message, "echo: hi");
  server.removeService("echo.Echo");
  assert.deepEqual(server.registeredServices(), []);
  await assert.rejects(client.unary(req()), (e) => e.code === StatusCode.UNIMPLEMENTED);
});
