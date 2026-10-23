// Echo demo: all four gRPC method shapes over one in-memory data
// channel. `node js/examples/echo_demo.js`
//
// The stub echo_grpc_dc.js came from the generated protoc plugin; the
// messages in echo_pb.js are hand-written (see that file for why).

import { Channel, Server, StatusCode, StatusError, memoryDataChannelPair } from "../index.js";
import { EchoRequest, EchoResponse } from "./echo_pb.js";
import { EchoClient, createEchoService } from "./echo_grpc_dc.js";

const handlers = {
  async unary(req, ctx) {
    if (req.message === "fail") {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
    }
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

const req = (message, count = 0) => new EchoRequest({ message, count });

async function* fromList(items) {
  yield* items;
}

const [a, b] = memoryDataChannelPair();
const server = new Server();
server.addService(createEchoService(handlers));
server.serve(b);

const client = new EchoClient(new Channel(a));

const unary = await client.unary(req("hello"));
console.log(`unary        -> ${unary.message} (index ${unary.index})`);

const ticks = [];
for await (const resp of await client.serverStream(req("tick", 3))) {
  ticks.push(`${resp.message}#${resp.index}`);
}
console.log(`server-stream-> ${ticks.join(", ")}`);

const joined = await client.clientStream(fromList([req("a"), req("b"), req("c")]));
console.log(`client-stream-> ${joined.message} (${joined.index} parts)`);

const echoed = [];
for await (const resp of await client.bidi(fromList([req("x"), req("y")]))) {
  echoed.push(resp.message);
}
console.log(`bidi         -> ${echoed.join(", ")}`);
