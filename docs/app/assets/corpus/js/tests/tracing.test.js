// Homegrown tracing: traceparent propagation + span observer.
// Client and server hooks observe one shared trace id with the
// server span parented to the client span; dormant without one.
import assert from "node:assert/strict";
import test from "node:test";

import {
  Channel,
  Server,
  StatusCode,
  StatusError,
  memoryDataChannelPair,
  setTraceFilter,
  setTracer,
} from "../index.js";
import { EchoRequest, EchoResponse } from "../examples/echo_pb.js";
import { EchoClient, createEchoService } from "../examples/echo_grpc_dc.js";

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

function recorder() {
  const starts = [];
  const ends = [];
  return {
    starts,
    ends,
    tracer: {
      onStart: (kind, method, traceId, spanId, parentSpanId) =>
        starts.push({ kind, method, traceId, spanId, parentSpanId }),
      onEnd: (kind, method, traceId, spanId, status) =>
        ends.push({ kind, method, traceId, spanId, status }),
    },
  };
}

function setup(tracer) {
  setTracer(tracer);
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers()));
  server.serve(b);
  return new EchoClient(new Channel(a));
}

test("unary propagates one parented trace", async () => {
  const rec = recorder();
  const client = setup(rec.tracer);
  try {
    const resp = await client.unary(new EchoRequest({ message: "hello" }));
    assert.equal(resp.message, "echo: hello");
  } finally {
    setTracer(null);
  }
  assert.deepEqual(rec.starts.map((s) => s.kind), ["client", "server"]);
  const [clientSpan, serverSpan] = rec.starts;
  assert.equal(clientSpan.method, "/echo.Echo/Unary");
  assert.equal(serverSpan.method, "/echo.Echo/Unary");
  assert.equal(clientSpan.traceId, serverSpan.traceId);
  assert.equal(clientSpan.traceId.length, 32);
  assert.equal(serverSpan.parentSpanId, clientSpan.spanId);
  assert.equal(clientSpan.parentSpanId, "");
  assert.equal(rec.ends.length, 2);
  assert.ok(rec.ends.every((e) => e.status === "OK"));
  assert.equal(rec.ends.find((e) => e.kind === "client").spanId, clientSpan.spanId);
  assert.equal(rec.ends.find((e) => e.kind === "server").spanId, serverSpan.spanId);
});

test("incoming traceparent is continued", async () => {
  const rec = recorder();
  const client = setup(rec.tracer);
  const traceId = "a".repeat(32);
  const spanId = "b".repeat(16);
  try {
    await client.unary(new EchoRequest({ message: "hello" }), {
      metadata: { traceparent: `00-${traceId}-${spanId}-01` },
    });
  } finally {
    setTracer(null);
  }
  assert.equal(rec.starts[0].traceId, traceId);
  assert.equal(rec.starts[0].parentSpanId, spanId);
});

test("error status observed on both ends", async () => {
  const rec = recorder();
  const client = setup(rec.tracer);
  try {
    await assert.rejects(client.unary(new EchoRequest({ message: "fail" })));
  } finally {
    setTracer(null);
  }
  const byKind = Object.fromEntries(rec.ends.map((e) => [e.kind, e.status]));
  assert.equal(byKind.client, "INVALID-ARGUMENT");
  assert.equal(byKind.server, "INVALID-ARGUMENT");
});

test("demo prints one parented trace", async () => {
  const { runDemo } = await import("../examples/tracing_demo.js");
  const lines = [];
  const tracer = await runDemo((line) => lines.push(line));
  assert.equal(lines.length, 4);
  const starts = tracer.events.filter((e) => e[0] === "start");
  assert.deepEqual(starts.map((s) => s[1]), ["client", "server"]);
  assert.equal(starts[0][2], starts[1][2]);
  assert.equal(starts[1][4], starts[0][3]);
  const joined = lines.join("\n");
  assert.match(joined, /\/echo\.Echo\/Unary/);
  assert.match(joined, /status=OK/);
});

test("OTLP example exports parented spans", async () => {
  const { OtlpTracer } = await import("../examples/otlp_tracer.js");
  const sent = [];
  const tracer = new OtlpTracer({
    serviceName: "echo-test",
    sender: (payload) => sent.push(payload),
  });
  const client = setup(tracer);
  try {
    await client.unary(new EchoRequest({ message: "hello" }));
    await tracer.flush();
  } finally {
    setTracer(null);
  }
  assert.equal(sent.length, 1);
  const resource = sent[0].resourceSpans[0];
  assert.equal(resource.resource.attributes[0].value.stringValue, "echo-test");
  const spans = resource.scopeSpans[0].spans;
  assert.equal(spans.length, 2);
  const clientSpan = spans.find((s) => s.kind === 3);
  const serverSpan = spans.find((s) => s.kind === 2);
  assert.equal(clientSpan.traceId, serverSpan.traceId);
  assert.equal(serverSpan.parentSpanId, clientSpan.spanId);
  assert.deepEqual(clientSpan.status, { code: 1 });
});

test("filter restricts methods", async () => {
  const rec = recorder();
  const client = setup(rec.tracer);
  try {
    setTraceFilter("/echo.Echo/ServerStream");
    await client.unary(new EchoRequest({ message: "hello" }));
    assert.deepEqual(rec.starts, []);
    for await (const _ of await client.serverStream(new EchoRequest({ message: "tick", count: 1 }))) {}
    assert.deepEqual(
      rec.starts.map((s) => s.method),
      ["/echo.Echo/ServerStream", "/echo.Echo/ServerStream"],
    );
    setTraceFilter("");
  } finally {
    setTracer(null);
    setTraceFilter("");
  }
});

test("dormant without a tracer", async () => {
  const client = setup(null);
  const resp = await client.unary(new EchoRequest({ message: "hello" }));
  assert.equal(resp.message, "echo: hello");
});
