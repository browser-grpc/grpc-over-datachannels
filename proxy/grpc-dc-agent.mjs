#!/usr/bin/env node
// grpc-dc-agent: the server side of the ingress proxy story.
// Binds a WebRTC-Direct listener (no signaling server; the
// printed multiaddr is the agent's identity) and serves a
// generated grpc-dc service on every accepted "grpc" channel.
//
// This agent serves the Echo demo service; a real deployment
// replaces createEchoService(handlers) with its own generated
// service — the listener/accept/serve shape is the product.
//
//   node proxy/grpc-dc-agent.mjs [--address 127.0.0.1] [--port 4001]
//   # prints: AGENT_MULTIADDR=/ip4/127.0.0.1/udp/4001/webrtc-direct/certhash/...

import { pathToFileURL } from "node:url";

import { Server, StatusCode, StatusError } from "../js/index.js";
import { EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { acceptDirectEndpoint, directListener } from "../js/src/webrtc_direct.js";

export const echoHandlers = {
  async unary(req, ctx) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
    if (req.delayMs > 0) await new Promise((resolve) => setTimeout(resolve, req.delayMs));
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

export async function startAgent({ address = "127.0.0.1", port = 0, handlers = echoHandlers, createService = createEchoService } = {}) {
  const listener = await directListener({ address, port });
  const server = new Server();
  server.addService(createService(handlers));
  const served = [];
  let closed = false;
  const acceptLoop = (async () => {
    while (!closed) {
      let endpoint;
      try {
        endpoint = await acceptDirectEndpoint(listener);
      } catch {
        return; // listener closed
      }
      served.push(endpoint);
      server.serve(endpoint);
    }
  })();
  return {
    listener,
    multiaddr: listener.multiaddr(),
    close: async () => {
      closed = true;
      for (const endpoint of served) {
        await endpoint.directEndpoint?.close().catch(() => {});
      }
      listener.close();
      // A pending accept() may never settle once the socket
      // is closed; do not wait for it indefinitely.
      await Promise.race([
        acceptLoop.catch(() => {}),
        new Promise((resolve) => setTimeout(resolve, 500)),
      ]);
    },
  };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const value = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : fallback;
  };
  const agent = await startAgent({
    address: value("--address", "127.0.0.1"),
    port: Number(value("--port", "4001")),
  });
  console.log(`AGENT_MULTIADDR=${agent.multiaddr}`);
  console.log("grpc-dc-agent: serving Echo over WebRTC-Direct");
}
