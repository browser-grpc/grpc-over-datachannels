// Multi-service tracing (beta): client -> front callee -> downstream
// service, one trace across all three hops.
//
// Run: node examples/tracing/multiservice.mjs
//
// The front callee's handler makes its outbound call through a
// context-bound channel (Channel.withTraceContext), so the
// downstream spans join the same trace with no manual metadata
// handling. The printing observer shows the parent chain:
//
//   client span
//     -> front server span
//       -> outbound client span
//         -> downstream server span
//
// With no observer registered, nothing is printed and no
// traceparent header is sent (tracing is dormant by default).
import { Channel, Server, memoryDataChannelPair, setTracer } from "../../js/index.js";
import { EchoRequest, EchoResponse } from "../../js/examples/echo_pb.js";
import { EchoClient, createEchoService } from "../../js/examples/echo_grpc_dc.js";

setTracer({
  onStart(kind, method, traceId, spanId, parentSpanId) {
    console.log(`-> ${kind.padEnd(6)} ${method} span=${spanId} parent=${parentSpanId || "-"}`);
  },
  onEnd(kind, method, traceId, spanId, status, durationMs) {
    console.log(`<- ${kind.padEnd(6)} ${method} span=${spanId} status=${status} ${durationMs.toFixed(2)}ms`);
  },
});

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

// Downstream service.
const [a2, b2] = memoryDataChannelPair();
const back = new Server();
back.addService(createEchoService(handlers()));
back.serve(b2);
const downstreamChannel = new Channel(a2);

// Front callee: its handler calls the downstream service.
const frontHandlers = {
  ...handlers(),
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
setTracer(null);
