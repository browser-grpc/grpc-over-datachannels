// Plugin process (Node): serves Echo over a Unix socket to
// the Rust host (examples/plugin-host, rust plugin_host.rs).
// The host routes /echo.Echo/* calls here DC-to-DC; clients
// only ever dial the host.
//
//   node examples/plugin-host/plugin.mjs [sockdir]
import { Server } from "../../js/index.js";
import { EchoResponse } from "../../js/examples/echo_pb.js";
import { createEchoService } from "../../js/examples/echo_grpc_dc.js";
import { udsChannel } from "../../js/src/stdio.js";

const dir = process.argv[2] ?? ".";
const handlers = {
  async unary(req) {
    return new EchoResponse({ message: `echo: ${req.message} (from plugin)`, index: 0 });
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

const channel = await udsChannel(`${dir}/plugin.sock`);
const server = new Server();
server.addService(createEchoService(handlers));
server.serve(channel.endpoint);
console.log("plugin: serving echo.Echo on plugin.sock");
