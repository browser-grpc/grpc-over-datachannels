// OTLP export (beta): the multi-service trace, exported as
// OTLP/JSON to an OpenTelemetry collector.
//
// Run:  node examples/tracing/otlp.mjs
//
// With no collector configured the example is self-verifying:
// it starts a throwaway collector on 127.0.0.1, runs the nested
// call chain (client -> front callee -> downstream service),
// flushes the exporter at it, and checks the received payload —
// four spans, one trace id, the full parent chain, OTLP kinds
// (CLIENT=3 / SERVER=2) and service.name. Prints
// OTLP_EXAMPLE_OK and exits 0 on success.
//
// To export to a real collector instead, set
// OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://localhost:4318/v1/traces
// (the standard OTel env var); the self-check collector is then
// skipped and the spans go to that endpoint.
//
// The exporter itself lives in js/examples/otlp_tracer.js — an
// example span observer, deliberately NOT in the runtime: the
// generated runtimes stay dependency-free, and sampling/export
// stay the application's choice.
import assert from "node:assert/strict";
import http from "node:http";

import { Channel, Server, memoryDataChannelPair, setTracer } from "../../js/index.js";
import { EchoRequest, EchoResponse } from "../../js/examples/echo_pb.js";
import { EchoClient, createEchoService } from "../../js/examples/echo_grpc_dc.js";
import { OtlpTracer } from "../../js/examples/otlp_tracer.js";

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

// --- collector: real endpoint from env, else a local capture ---
const realEndpoint = process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT;
let endpoint = realEndpoint;
let collector = null;
let captured = null;
let captureResolve;
const captureDone = new Promise((resolve) => { captureResolve = resolve; });
if (!endpoint) {
  collector = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      captured = JSON.parse(Buffer.concat(chunks).toString());
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("{}");
      captureResolve(captured);
    });
  });
  await new Promise((resolve) => collector.listen(0, "127.0.0.1", resolve));
  endpoint = `http://127.0.0.1:${collector.address().port}/v1/traces`;
}

const tracer = new OtlpTracer({ endpoint, serviceName: "grpc-dc-otlp-example" });
setTracer(tracer);
try {
  // Downstream service.
  const [a2, b2] = memoryDataChannelPair();
  const back = new Server();
  back.addService(createEchoService(handlers()));
  back.serve(b2);
  const downstreamChannel = new Channel(a2);

  // Front callee: parents its outbound call to the inbound span.
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
  assert.equal(resp.message, "echo: nested");
} finally {
  setTracer(null);
}

await tracer.flush();

if (collector) {
  const payload = await Promise.race([
    captureDone,
    new Promise((_, reject) => setTimeout(() => reject(new Error("collector timeout")), 5000)),
  ]);
  collector.close();
  const resourceSpans = payload.resourceSpans;
  assert.equal(resourceSpans.length, 1);
  const attrs = Object.fromEntries(
    resourceSpans[0].resource.attributes.map((a) => [a.key, a.value.stringValue]),
  );
  assert.equal(attrs["service.name"], "grpc-dc-otlp-example");
  const spans = resourceSpans[0].scopeSpans[0].spans;
  assert.equal(spans.length, 4, `spans: ${spans.length}`);
  assert.ok(spans.every((s) => s.traceId === spans[0].traceId), "one trace id");
  assert.ok(spans.every((s) => BigInt(s.endTimeUnixNano) >= BigInt(s.startTimeUnixNano)));
  // Ends arrive innermost-first; rebuild the chain by parent ids.
  const byId = new Map(spans.map((s) => [s.spanId, s]));
  const roots = spans.filter((s) => !s.parentSpanId);
  assert.equal(roots.length, 1, "one root span");
  assert.equal(roots[0].kind, 3, "root is CLIENT");
  let current = roots[0];
  const kinds = [current.kind];
  for (let depth = 0; depth < 3; depth++) {
    const child = spans.find((s) => s.parentSpanId === current.spanId);
    assert.ok(child, `child at depth ${depth + 1}`);
    kinds.push(child.kind);
    current = child;
  }
  assert.deepEqual(kinds, [3, 2, 3, 2], "client,server,client,server");
  console.log(`OTLP_EXAMPLE_OK spans=${spans.length} trace=${spans[0].traceId} (self-check collector)`);
} else {
  console.log(`OTLP_EXAMPLE_OK exported to ${endpoint}`);
}
