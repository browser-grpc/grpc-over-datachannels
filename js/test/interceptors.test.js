// Server interceptors (JS): install order, rejection ends
// the call before the handler, returned claims land on
// ctx.claims when no auth claims are set.

import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

let handled = 0;
let seenClaims = null;
const handlers = {
  async unary(req, ctx) {
    handled += 1;
    seenClaims = ctx.claims;
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

test("interceptors run in order, reject before handler, pass claims", async () => {
  handled = 0;
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  const order = [];
  server.addService(createEchoService(handlers));
  server.addInterceptor(async ({ path }) => {
    order.push(`first:${path}`);
    return { sub: "interceptor-user" };
  });
  server.addInterceptor(async ({ metadata }) => {
    order.push("second");
    if (metadata["x-block"] === "yes") {
      throw new StatusError(StatusCode.UNAUTHENTICATED, "blocked by interceptor");
    }
  });
  server.serve(b);
  const base = new Channel(a);
  const client = new EchoClient(base);
  const resp = await client.unary(new EchoRequest({ message: "hi" }));
  assert.equal(resp.message, "echo: hi");
  assert.equal(handled, 1);
  assert.deepEqual(order, ["first:/echo.Echo/Unary", "second"]);
  assert.equal(seenClaims.sub, "interceptor-user");

  const blocked = new EchoClient(
    base.withMetadata({ "x-block": "yes" }),
  );
  await assert.rejects(
    blocked.unary(new EchoRequest({ message: "hi" })),
    (e) => e.code === StatusCode.UNAUTHENTICATED,
  );
  assert.equal(handled, 1, "handler must not run when an interceptor rejects");
});
