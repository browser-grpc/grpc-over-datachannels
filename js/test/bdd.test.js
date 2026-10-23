import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { BDD_SCENARIOS } from "./bdd_scenarios.generated.js";

// BDD: interprets the generated behavior scenarios generated from
// the BDD specification (prose in BDD.md) against a loopback
// client+server — the executable examples.

function handlers() {
  return {
    async unary(req, ctx) {
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
      if (req.delayMs > 0) {
        await new Promise((r) => setTimeout(r, req.delayMs));
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
        if (req.message === "fail") {
          throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
        }
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
  const channel = new Channel(a);
  return { channel, client: new EchoClient(channel) };
}

const req = (message, count = 0) => new EchoRequest({ message, count });

async function* fromList(items) {
  yield* items;
}

async function collect(iterable) {
  const out = [];
  for await (const item of iterable) out.push(item);
  return out;
}

for (const c of BDD_SCENARIOS) {
  test(`bdd: ${c.name}`, async () => {
    const { channel, client } = setup();
    if (c.kind === "unary") {
      const options = c.metadata ? { metadata: { "x-echo": c.metadata } } : undefined;
      if (c.expectStatus >= 0) {
        await assert.rejects(client.unary(req(c.messages[0]), options), (e) => {
          assert.equal(e.code, c.expectStatus);
          return true;
        });
      } else {
        const resp = await client.unary(req(c.messages[0]), options);
        assert.equal(resp.message, c.expectMessage);
        assert.equal(resp.index, c.expectNum);
      }
    } else if (c.kind === "server-stream") {
      const got = await collect(await client.serverStream(req(c.messages[0], c.count)));
      assert.equal(got.length, c.expectNum);
      got.forEach((resp, i) => {
        assert.equal(resp.message, c.expectMessage);
        assert.equal(resp.index, i);
      });
    } else if (c.kind === "client-stream") {
      const resp = await client.clientStream(fromList(c.messages.map((m) => req(m))));
      assert.equal(resp.message, c.expectMessage);
      assert.equal(resp.index, c.expectNum);
    } else if (c.kind === "bidi") {
      const got = await collect(await client.bidi(fromList(c.messages.map((m) => req(m)))));
      assert.equal(got.length, c.expectNum);
      got.forEach((resp, i) => {
        assert.equal(resp.message, c.messages[i]);
        assert.equal(resp.index, i);
      });
    } else if (c.kind === "server-stream-fail") {
      await assert.rejects(collect(await client.serverStream(req(c.messages[0], c.count))), (e) => {
        assert.equal(e.code, c.expectStatus);
        return true;
      });
    } else if (c.kind === "bidi-fail") {
      await assert.rejects(
        collect(await client.bidi(fromList(c.messages.map((m) => req(m))))),
        (e) => {
          assert.equal(e.code, c.expectStatus);
          return true;
        },
      );
    } else if (c.kind === "deadline") {
      await assert.rejects(
        client.unary(new EchoRequest({ message: c.messages[0], delayMs: c.count }), { timeout: 100 }),
        (e) => {
          assert.equal(e.code, c.expectStatus);
          return true;
        },
      );
    } else if (c.kind === "cancel") {
      const responses = await client.serverStream(req(c.messages[0], c.count));
      let got = 0;
      // Breaking the iteration tears the call down (the
      // responses generator's finally aborts the stream);
      // reaching this line at all proves it terminated.
      for await (const resp of responses) {
        assert.equal(resp.message, c.messages[0]);
        got++;
        if (got === 1) break;
      }
      assert.equal(got, 1);
    } else if (c.kind === "raw-unary") {
      await assert.rejects(
        channel.unary(c.path, req(c.messages[0]), EchoRequest, EchoResponse),
        (e) => {
          assert.equal(e.code, c.expectStatus);
          return true;
        },
      );
    } else {
      assert.fail(`unknown bdd kind: ${c.kind}`);
    }
  });
}
