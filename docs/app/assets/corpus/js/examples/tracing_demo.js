// Tracing demo: a printing span observer over an in-process call.
//
// Run: node js/examples/tracing_demo.js
//
// Registers an observer that prints one line per span start/end.
// The client and server spans share one trace id; the server span's
// parent is the client span. With no observer registered nothing
// is printed and no traceparent header is sent (dormant by default).
import {
  Channel,
  Server,
  memoryDataChannelPair,
  setTracer,
} from "../index.js";
import { EchoRequest, EchoResponse } from "./echo_pb.js";
import { EchoClient, createEchoService } from "./echo_grpc_dc.js";

export class PrintingTracer {
  constructor(out = console.log) {
    this.out = out;
    this.events = [];
  }

  onStart(kind, method, traceId, spanId, parentSpanId) {
    this.events.push(["start", kind, traceId, spanId, parentSpanId]);
    this.out(
      `-> ${kind} ${method} trace=${traceId} span=${spanId} parent=${parentSpanId || "-"}`,
    );
  }

  onEnd(kind, method, traceId, spanId, status) {
    this.events.push(["end", kind, traceId, spanId, status]);
    this.out(`<- ${kind} ${method} trace=${traceId} span=${spanId} status=${status}`);
  }
}

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

export async function runDemo(out) {
  const tracer = new PrintingTracer(out);
  setTracer(tracer);
  try {
    const [a, b] = memoryDataChannelPair();
    const server = new Server();
    server.addService(createEchoService(handlers()));
    server.serve(b);
    const client = new EchoClient(new Channel(a));
    const resp = await client.unary(new EchoRequest({ message: "hello" }));
    if (resp.message !== "echo: hello") throw new Error(resp.message);
  } finally {
    setTracer(null);
  }
  return tracer;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await runDemo();
}
