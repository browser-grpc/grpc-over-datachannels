// Generated-runtime WebRTC-Direct adapter (Node): a generated
// Echo client calls a generated Echo server addressed only by
// the listener's certhash multiaddr -- no ICE, no SDP. The
// adapter under test is src/webrtc_direct.js (generated from
// racket/runtime-js.rkt) over webrtc/js/direct.js.

import assert from "node:assert/strict";
import test from "node:test";

import { Channel, Server, StatusCode, StatusError } from "../index.js";
import {
  acceptDirectEndpoint,
  directClientEndpoint,
  directClientStackEndpoint,
  directListener,
  openDirectChannel,
} from "../src/webrtc_direct.js";
import { EchoRequest } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";
import { EchoResponse } from "../examples/echo_pb.js";

function handlers() {
  return {
    async unary(req) {
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
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

const req = (message, count = 0) => new EchoRequest({ message, count });

test("lossy unordered application channel next to grpc", { timeout: 30000 }, async () => {
  const listener = await directListener();
  try {
    const acceptedChannels = [];
    // Server side: accept the raw stack endpoint via the
    // listener's own accept (the adapter's
    // acceptDirectEndpoint would consume the grpc channel;
    // here the test needs the stack endpoint itself).
    const stackAccept = listener.accept();
    const clientStack = await directClientStackEndpoint(listener.multiaddr());
    const channel = openDirectChannel(clientStack, {
      label: "telemetry",
      ordered: false,
      reliability: { kind: "retransmits", count: 0 },
    });
    assert.equal(channel.label, "telemetry");
    const serverStack = await stackAccept;
    const got = new Promise((resolve) => {
      serverStack.onchannel = (ch) => {
        acceptedChannels.push(ch.label);
        ch.onmessage = (e) => resolve(Buffer.from(e.data).toString());
      };
    });
    channel.send(Buffer.from("ping-lossy"));
    assert.equal(await got, "ping-lossy");
    assert.deepEqual(acceptedChannels, ["telemetry"]);
    await clientStack.closeDirect();
    await serverStack.close();
  } finally {
    listener.close();
  }
});

test("generated Echo over WebRTC-Direct by multiaddr", { timeout: 30000 }, async () => {
  const listener = await directListener();
  try {
    const serverEndpointPromise = acceptDirectEndpoint(listener);
    const server = new Server();
    server.addService(createEchoService(handlers()));
    serverEndpointPromise.then((endpoint) => server.serve(endpoint));

    const clientEndpoint = await directClientEndpoint(listener.multiaddr());
    const client = new EchoClient(new Channel(clientEndpoint));
    try {
      const unary = await client.unary(req("hello"));
      assert.equal(unary.message, "echo: hello");

      await assert.rejects(client.unary(req("fail")), (err) => {
        assert.equal(err.code, StatusCode.INVALID_ARGUMENT);
        assert.ok(err.message.includes("asked to fail"), err.message);
        return true;
      });

      const got = [];
      for await (const resp of await client.serverStream(req("tick", 3))) got.push(resp);
      assert.deepEqual(got.map((r) => r.index), [0, 1, 2]);
      assert.ok(got.every((r) => r.message === "tick"));
    } finally {
      await clientEndpoint.directEndpoint.closeDirect?.() ??
        clientEndpoint.directEndpoint.close();
      const serverEndpoint = await serverEndpointPromise;
      await serverEndpoint.directEndpoint.close();
    }
  } finally {
    listener.close();
  }
});
