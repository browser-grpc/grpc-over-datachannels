// Nested tracing demo: a front handler makes a downstream call via
// a trace-context-bound channel; the printing observer shows one
// tree of spans under a single trace id.
//
// Run: node js/examples/tracing_nested_demo.mjs
import { Channel, Server, memoryDataChannelPair, setTracer } from "../index.js";
import { EchoRequest, EchoResponse } from "./echo_pb.js";
import { EchoClient, createEchoService } from "./echo_grpc_dc.js";
import { PrintingTracer } from "./tracing_demo.js";

const tracer = new PrintingTracer();
setTracer(tracer);
try {
  const handlers = {
    async unary(req) {
      return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
    },
    async *serverStream(req) {
      for (let i = 0; i < Math.max(0, req.count); i++) yield new EchoResponse({ message: req.message, index: i });
    },
    async clientStream(requests) {
      const parts = [];
      for await (const req of requests) parts.push(req.message);
      return new EchoResponse({ message: parts.join("+"), index: parts.length });
    },
    async *bidi(requests) {
      let index = 0;
      for await (const req of requests) yield new EchoResponse({ message: req.message, index: index++ });
    },
  };
  // Downstream service.
  const [a2, b2] = memoryDataChannelPair();
  const back = new Server();
  back.addService(createEchoService(handlers));
  back.serve(b2);
  const downstreamChannel = new Channel(a2);

  // Front callee: handler makes an outbound call through a
  // context-bound channel; no manual metadata handling.
  const frontHandlers = {
    ...handlers,
    async unary(req, ctx) {
      const downstream = new EchoClient(
        downstreamChannel.withTraceContext(ctx.traceContext),
      );
      return downstream.unary(new EchoRequest({ message: "nested" }));
    },
  };
  const [a, b] = memoryDataChannelPair();
  const front = new Server();
  front.addService(createEchoService(frontHandlers));
  front.serve(b);
  const client = new EchoClient(new Channel(a));

  const resp = await client.unary(new EchoRequest({ message: "hello" }));
  console.log(`response: ${resp.message}`);
} finally {
  setTracer(null);
}
