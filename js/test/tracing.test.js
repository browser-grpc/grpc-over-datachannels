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
      onEnd: (kind, method, traceId, spanId, status, durationMs) =>
        ends.push({ kind, method, traceId, spanId, status, durationMs }),
    },
  };
}

function setup(tracer, serviceHandlers = handlers()) {
  setTracer(tracer);
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(serviceHandlers));
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
  assert.ok(rec.ends.every((e) => typeof e.durationMs === "number" && e.durationMs >= 0));
  assert.equal(rec.ends.find((e) => e.kind === "client").spanId, clientSpan.spanId);
  assert.equal(rec.ends.find((e) => e.kind === "server").spanId, serverSpan.spanId);
});

test("nested callee call joins the trace (explicit context)", async () => {
  const rec = recorder();
  let seenCtx = null;
  setTracer(rec.tracer);
  try {
    // Downstream service.
    const [a2, b2] = memoryDataChannelPair();
    const back = new Server();
    back.addService(createEchoService(handlers()));
    back.serve(b2);
    const downstreamChannel = new Channel(a2);

    // Front callee: handler makes an outbound call through a
    // context-bound channel; no manual metadata handling.
    const frontHandlers = {
      ...handlers(),
      async unary(req, ctx) {
        seenCtx = ctx;
        const downstream = new EchoClient(
          downstreamChannel.withTraceContext(ctx.traceContext),
        );
        const resp = await downstream.unary(new EchoRequest({ message: "nested" }));
        return resp;
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
  assert.deepEqual(rec.starts.map((s) => s.kind), ["client", "server", "client", "server"]);
  const [outerClient, outerServer, innerClient, innerServer] = rec.starts;
  assert.ok(rec.starts.every((s) => s.traceId === outerClient.traceId));
  assert.equal(outerServer.parentSpanId, outerClient.spanId);
  assert.equal(innerClient.parentSpanId, outerServer.spanId);
  assert.equal(innerServer.parentSpanId, innerClient.spanId);
  assert.equal(seenCtx.traceContext.spanId, outerServer.spanId);
  assert.equal(rec.ends.length, 4);
  assert.ok(rec.ends.every((e) => typeof e.durationMs === "number" && e.durationMs >= 0));
});

test("root context groups client calls", async () => {
  const rec = recorder();
  const { newTraceContext, traceEnd } = await import("../index.js");
  setTracer(rec.tracer);
  const root = newTraceContext("internal", "workflow");
  assert.ok(root);
  try {
    const [a, b] = memoryDataChannelPair();
    const server = new Server();
    server.addService(createEchoService(handlers()));
    server.serve(b);
    const client = new EchoClient(new Channel(a).withTraceContext(root));
    await client.unary(new EchoRequest({ message: "one" }));
    await client.unary(new EchoRequest({ message: "two" }));
  } finally {
    traceEnd("internal", "workflow", root, "OK");
    setTracer(null);
  }
  const clients = rec.starts.filter((s) => s.kind === "client");
  assert.equal(clients.length, 2);
  assert.ok(clients.every((s) => s.parentSpanId === root.spanId));
  assert.ok(rec.starts.every((s) => s.traceId === root.traceId));
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

test("tracestate and baggage reach the server as metadata", async () => {
  const rec = recorder();
  let seen = null;
  const capturing = {
    ...handlers(),
    async unary(req, ctx) {
      seen = ctx.metadata;
      return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
    },
  };
  const client = setup(rec.tracer, capturing);
  try {
    await client.unary(new EchoRequest({ message: "hello" }), {
      metadata: { tracestate: "vendor=abc", baggage: "userId=42" },
    });
  } finally {
    setTracer(null);
  }
  assert.equal(seen.tracestate, "vendor=abc");
  assert.equal(seen.baggage, "userId=42");
  assert.match(seen.traceparent, /^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/);
});

test("not-sampled parent is honored and propagated", async () => {
  const rec = recorder();
  let seen = null;
  const capturing = {
    ...handlers(),
    async unary(req, ctx) {
      seen = ctx.metadata;
      return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
    },
  };
  const client = setup(rec.tracer, capturing);
  const traceId = "c".repeat(32);
  const spanId = "d".repeat(16);
  try {
    await client.unary(new EchoRequest({ message: "hello" }), {
      metadata: { traceparent: `00-${traceId}-${spanId}-00` },
    });
  } finally {
    setTracer(null);
  }
  assert.deepEqual(rec.starts, []);
  assert.deepEqual(rec.ends, []);
  assert.ok(seen.traceparent.startsWith(`00-${traceId}-`));
  assert.ok(seen.traceparent.endsWith("-00"));
});
