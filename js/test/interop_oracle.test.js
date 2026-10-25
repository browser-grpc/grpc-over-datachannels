// Interop oracle: our generated JS client runs the canonical
// grpc interop cases (grpc.testing.TestService, vendored in
// oracle/interop) against the OFFICIAL TestServiceServers —
// grpc-java and grpc-go — no bridge, direct HTTP/2
// (src/http2.js). Case semantics mirror grpc's
// AbstractInteropTest. Skips when an oracle is not built
// (Dockerfile.ci builds both).
//
// Per-call cancellation: the generated client takes an
// AbortSignal in call options ({signal}); aborting fails the
// call with CANCELLED, mirroring the upstream cancel cases.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer, connect } from "node:net";
import test from "node:test";

import { StatusCode } from "../index.js";
import { http2Channel } from "../src/http2.js";
import { TestServiceClient, UnimplementedServiceClient } from "../examples/interop/test_grpc_dc.js";
import { Empty } from "../examples/interop/empty_pb.js";
import {
  EchoStatus,
  Payload,
  ResponseParameters,
  SimpleRequest,
  StreamingInputCallRequest,
  StreamingOutputCallRequest,
} from "../examples/interop/messages_pb.js";

const ROOT = new URL("../..", import.meta.url).pathname;
const JAVA_DIR = `${ROOT}oracle/java`;

function javaClasspath(t) {
  const cpFile = `${JAVA_DIR}/target/cp.txt`;
  if (!existsSync(`${JAVA_DIR}/target/classes`) || !existsSync(cpFile)) {
    t.skip("java oracle not built (cd oracle/java && mvn package)");
    return null;
  }
  return `${JAVA_DIR}/target/classes:${readFileSync(cpFile, "utf8").trim()}`;
}

async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function startJavaTestServiceServer(t, port) {
  const cp = javaClasspath(t);
  if (!cp) return false;
  const proc = spawn(
    "java",
    ["-cp", cp, "io.grpc.testing.integration.TestServiceServer", `--port=${port}`, "--use_tls=false"],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  t.after(() => proc.kill());
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("TestServiceServer did not start")), 30000);
    const onData = (d) => {
      if (String(d).includes("Server started")) {
        clearTimeout(timer);
        resolve();
      }
    };
    proc.stdout.on("data", onData);
    proc.stderr.on("data", onData);
    proc.on("exit", (code) => reject(new Error(`TestServiceServer exited ${code}`)));
  });
  return true;
}

async function startGoTestServiceServer(t, port) {
  const binary = `${ROOT}oracle/go-interop/interop-server`;
  if (!existsSync(binary)) {
    t.skip("go interop server not built (cd oracle/go-interop && go build -o interop-server google.golang.org/grpc/interop/server)");
    return false;
  }
  const proc = spawn(binary, ["-port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  t.after(() => proc.kill());
  proc.on("exit", (code) => {
    if (code !== null && code !== 0) throw new Error(`go TestServiceServer exited ${code}`);
  });
  // The Go server prints no readiness line; poll the TCP port.
  const deadline = Date.now() + 30000;
  for (;;) {
    const open = await new Promise((resolve) => {
      const sock = connect(port, "127.0.0.1");
      sock.once("connect", () => { sock.end(); resolve(true); });
      sock.once("error", () => resolve(false));
    });
    if (open) return true;
    if (Date.now() > deadline) throw new Error("go TestServiceServer did not start");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

const zeros = (n) => new Uint8Array(n);

test("interop: JS client -> grpc-java TestServiceServer (HTTP/2)", { timeout: 180000 }, async (t) => {
  const port = await freePort();
  if (!(await startJavaTestServiceServer(t, port))) return;
  const channel = http2Channel(`127.0.0.1:${port}`);
  t.after(() => channel.endpoint.dataChannel.close());
  await interopCases(t, new TestServiceClient(channel), channel);
});

test("interop: JS client -> grpc-go TestServiceServer (HTTP/2)", { timeout: 180000 }, async (t) => {
  const port = await freePort();
  if (!(await startGoTestServiceServer(t, port))) return;
  const channel = http2Channel(`127.0.0.1:${port}`);
  t.after(() => channel.endpoint.dataChannel.close());
  await interopCases(t, new TestServiceClient(channel), channel);
});

async function interopCases(t, client, channel) {
  await t.test("empty_unary", async () => {
    const resp = await client.emptyCall(new Empty());
    assert.ok(resp instanceof Empty);
  });

  await t.test("large_unary", async () => {
    const resp = await client.unaryCall(new SimpleRequest({
      responseSize: 314159,
      payload: new Payload({ body: zeros(271828) }),
    }));
    assert.equal(resp.payload.body.length, 314159);
    assert.ok(resp.payload.body.every((b) => b === 0));
  });

  await t.test("client_streaming", async () => {
    const sizes = [27182, 8, 1828, 45904];
    async function* reqs() {
      for (const size of sizes) {
        yield new StreamingInputCallRequest({ payload: new Payload({ body: zeros(size) }) });
      }
    }
    const resp = await client.streamingInputCall(reqs());
    assert.equal(resp.aggregatedPayloadSize, sizes.reduce((a, b) => a + b, 0));
  });

  await t.test("server_streaming", async () => {
    const sizes = [31415, 9, 2653, 58979];
    const req = new StreamingOutputCallRequest({
      responseParameters: sizes.map((size) => new ResponseParameters({ size })),
    });
    let i = 0;
    for await (const resp of await client.streamingOutputCall(req)) {
      assert.equal(resp.payload.body.length, sizes[i]);
      i++;
    }
    assert.equal(i, sizes.length);
  });

  await t.test("ping_pong", async () => {
    const respSizes = [31415, 9, 2653, 58979];
    const reqSizes = [27182, 8, 1828, 45904];
    async function* reqs() {
      for (let i = 0; i < respSizes.length; i++) {
        yield new StreamingOutputCallRequest({
          responseParameters: [new ResponseParameters({ size: respSizes[i] })],
          payload: new Payload({ body: zeros(reqSizes[i]) }),
        });
      }
    }
    let i = 0;
    for await (const resp of await client.fullDuplexCall(reqs())) {
      assert.equal(resp.payload.body.length, respSizes[i]);
      i++;
    }
    assert.equal(i, respSizes.length);
  });

  await t.test("empty_stream", async () => {
    async function* reqs() {}
    let n = 0;
    for await (const _resp of await client.fullDuplexCall(reqs())) n++;
    assert.equal(n, 0);
  });

  await t.test("custom_metadata", async () => {
    // Upstream custom_metadata: echo-initial returns as
    // response initial metadata, echo-trailing-bin (binary
    // 0x0a 0x0b ...; base64 on our wire) as trailers. Asserted
    // on UnaryCall and FullDuplexCall, mirroring
    // AbstractInteropTest.
    const trailingBin = Buffer.from([0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b]).toString("base64");
    const metadata = {
      "x-grpc-test-echo-initial": "test_initial_metadata_value",
      "x-grpc-test-echo-trailing-bin": trailingBin,
    };
    let headers = null;
    let trailers = null;
    const hooks = {
      onHeaders: (md) => (headers = md),
      onTrailers: (md) => (trailers = md),
    };
    const resp = await client.unaryCall(
      new SimpleRequest({ responseSize: 1, payload: new Payload({ body: zeros(1) }) }),
      { metadata, ...hooks },
    );
    assert.equal(resp.payload.body.length, 1);
    assert.equal(headers?.["x-grpc-test-echo-initial"], "test_initial_metadata_value");
    assert.equal(trailers?.["x-grpc-test-echo-trailing-bin"], trailingBin);

    headers = null;
    trailers = null;
    async function* reqs() {
      yield new StreamingOutputCallRequest({
        responseParameters: [new ResponseParameters({ size: 1 })],
        payload: new Payload({ body: zeros(1) }),
      });
    }
    let n = 0;
    for await (const _resp of await client.fullDuplexCall(reqs(), { metadata, ...hooks })) n++;
    assert.equal(n, 1);
    assert.equal(headers?.["x-grpc-test-echo-initial"], "test_initial_metadata_value");
    assert.equal(trailers?.["x-grpc-test-echo-trailing-bin"], trailingBin);
  });

  await t.test("status_code_and_message", async () => {
    const req = new SimpleRequest({
      responseStatus: new EchoStatus({ code: 2, message: "test status message" }),
    });
    await assert.rejects(
      client.unaryCall(req),
      (e) => e.code === 2 && e.message.endsWith("test status message"),
    );
  });

  await t.test("special_status_message", async () => {
    const msg = "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n";
    const req = new SimpleRequest({
      responseStatus: new EchoStatus({ code: 2, message: msg }),
    });
    await assert.rejects(
      client.unaryCall(req),
      (e) => e.code === 2 && e.message.endsWith(msg),
    );
  });

  await t.test("unimplemented_method", async () => {
    const unimpl = new UnimplementedServiceClient(channel);
    await assert.rejects(
      unimpl.unimplementedCall(new Empty()),
      (e) => e.code === StatusCode.UNIMPLEMENTED,
    );
  });

  await t.test("unimplemented_service", async () => {
    await assert.rejects(
      channel.unary("/grpc.testing.UnimplementedService2/UnimplementedCall", new Empty(), Empty, Empty),
      (e) => e.code === StatusCode.UNIMPLEMENTED,
    );
  });

  await t.test("cancel_after_begin", async () => {
    const ac = new AbortController();
    const responses = await client.streamingOutputCall(
      new StreamingOutputCallRequest({
        responseParameters: [new ResponseParameters({ size: 1 })],
        payload: new Payload({ body: zeros(1) }),
      }),
      { signal: ac.signal },
    );
    ac.abort();
    await assert.rejects(
      async () => {
        for await (const _resp of responses) {
          // cancelled before any response is consumed
        }
      },
      (e) => e.code === StatusCode.CANCELLED,
    );
  });

  await t.test("cancel_after_first_response", async () => {
    const ac = new AbortController();
    async function* reqs() {
      yield new StreamingOutputCallRequest({
        responseParameters: [new ResponseParameters({ size: 31415 })],
        payload: new Payload({ body: zeros(27182) }),
      });
    }
    const responses = await client.fullDuplexCall(reqs(), { signal: ac.signal });
    const it = responses[Symbol.asyncIterator]();
    const first = await it.next();
    assert.equal(first.value.payload.body.length, 31415);
    ac.abort();
    await assert.rejects(it.next(), (e) => e.code === StatusCode.CANCELLED);
  });

  await t.test("timeout_on_sleeping_server", async () => {
    async function* reqs() {
      yield new StreamingOutputCallRequest({ payload: new Payload({ body: zeros(27182) }) });
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
    await assert.rejects(
      async () => {
        for await (const _resp of await client.fullDuplexCall(reqs(), { timeout: 1 })) {
          // first response arrives; the sleeping request side
          // then trips the 1ms deadline
        }
      },
      (e) => e.code === StatusCode.DEADLINE_EXCEEDED,
    );
  });
}
