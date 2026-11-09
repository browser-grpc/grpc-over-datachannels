// HTTP/2 malformed-input corpus for the JS proxy ingress
// (oracle/bridge.mjs serveHttp2ToDc, the grpc-dc-proxy --http2
// surface): hostile or truncated inputs must terminate the
// affected call/connection with an error — never hang the
// proxy, never wedge the grpc-dc backend — and the proxy must
// keep answering well-formed calls after every case. This is
// the JS counterpart of rust/tests/http2_robustness.rs (the
// Rust proxy's corpus); the HTTP/2 framing/HPACK layer here is
// node:http2, so the corpus aims at what the bridge itself
// owns: connection abuse handling and LPM translation.
//
// Backend is an in-memory grpc-dc Echo server (no WebRTC), so
// the corpus stays fast and deterministic.

import assert from "node:assert/strict";
import http2 from "node:http2";
import net from "node:net";
import test from "node:test";
import { gzipSync } from "node:zlib";

import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";
import { createEchoService } from "../js/examples/echo_grpc_dc.js";
import { Endpoint, Server, StatusCode, StatusError, memoryDataChannelPair } from "../js/index.js";
import { LpmParser, lpm, serveHttp2ToDc } from "../oracle/bridge.mjs";

const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

function frameHeader(length, type, flags, streamId) {
  const out = Buffer.alloc(9);
  out.writeUIntBE(length, 0, 3);
  out[3] = type;
  out[4] = flags;
  out.writeUInt32BE(streamId, 5);
  return out;
}

async function startProxy(t) {
  const handlers = {
    async unary(req) {
      if (req.message === "fail") {
        throw new StatusError(StatusCode.INVALID_ARGUMENT, "asked to fail");
      }
      return new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
    },
    async *serverStream(req) {
      yield new EchoResponse({ message: req.message, index: 0 });
    },
    async clientStream(reqs) {
      let n = 0;
      for await (const _req of reqs) n++;
      return new EchoResponse({ message: "joined", index: n });
    },
    async *bidi(reqs) {
      for await (const req of reqs) {
        yield new EchoResponse({ message: `echo: ${req.message}`, index: 0 });
      }
    },
  };
  const [a, b] = memoryDataChannelPair();
  const server = new Server();
  server.addService(createEchoService(handlers));
  server.serve(b);
  const http2Server = await serveHttp2ToDc({ port: 0, endpoint: new Endpoint(a) });
  t.after(() => http2Server.close());
  return http2Server.address().port;
}

function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`timeout: ${label}`)), ms)),
  ]);
}

// One well-formed unary through the ingress; the liveness
// check after every hostile case.
function goodCall(port) {
  return withTimeout(
    new Promise((resolve, reject) => {
      const session = http2.connect(`http://127.0.0.1:${port}`);
      const stream = session.request({
        ":path": "/echo.Echo/Unary",
        ":method": "POST",
        ":scheme": "http",
        "content-type": "application/grpc",
        te: "trailers",
      });
      const chunks = [];
      let trailers = null;
      stream.on("data", (c) => chunks.push(c));
      stream.on("trailers", (h) => (trailers = h));
      stream.on("error", reject);
      stream.on("end", () => {
        session.close();
        resolve({ chunks: Buffer.concat(chunks), trailers });
      });
      stream.end(lpm(EchoRequest.encode(new EchoRequest({ message: "hello" }))));
    }),
    10000,
    "good call",
  ).then(({ chunks, trailers }) => {
    assert.equal(trailers["grpc-status"], "0");
    const parser = new LpmParser("identity");
    const messages = parser.push(chunks);
    assert.equal(EchoResponse.decode(messages[0]).message, "echo: hello");
  });
}

// Raw-socket interaction; resolves when the server closes the
// socket or the deadline passes (returns "closed"/"open").
function rawExchange(port, bytes, { endAfter = false, waitMs = 4000 } = {}) {
  return new Promise((resolve) => {
    const sock = net.connect(port, "127.0.0.1", () => {
      sock.write(bytes);
      if (endAfter) sock.end();
    });
    let sawGoaway = false;
    sock.on("data", (d) => {
      // GOAWAY frame type 0x7 at offset 3 of a frame header.
      for (let i = 0; i + 9 <= d.length; i++) {
        if (d[i + 3] === 0x7) sawGoaway = true;
      }
    });
    const timer = setTimeout(() => {
      sock.destroy();
      resolve(sawGoaway ? "goaway" : "open");
    }, waitMs);
    sock.on("close", () => {
      clearTimeout(timer);
      resolve(sawGoaway ? "goaway" : "closed");
    });
    sock.on("error", () => {});
  });
}

// One hostile HTTP/2 client call; resolves with trailers (or
// "stream-error") once the call terminates.
function hostileCall(port, { path = "/echo.Echo/Unary", headers = {}, write, end = true }) {
  return withTimeout(
    new Promise((resolve) => {
      const session = http2.connect(`http://127.0.0.1:${port}`);
      const stream = session.request({
        ":path": path,
        ":method": "POST",
        ":scheme": "http",
        "content-type": "application/grpc",
        te: "trailers",
        ...headers,
      });
      let trailers = null;
      stream.on("trailers", (h) => (trailers = h));
      stream.on("data", () => {});
      stream.on("error", () => {
        session.close();
        resolve("stream-error");
      });
      stream.on("end", () => {
        session.close();
        resolve(trailers ?? "no-trailers");
      });
      if (write) write(stream);
      if (end) stream.end();
    }),
    10000,
    `hostile call ${path}`,
  );
}

test("corpus: garbage instead of the HTTP/2 preface", async (t) => {
  const port = await startProxy(t);
  const outcome = await rawExchange(port, Buffer.from("GET / HTTP/1.1\r\n\r\ngarbagegarbage"));
  assert.ok(
    outcome === "closed" || outcome === "goaway",
    `server must drop a non-HTTP/2 connection, got ${outcome}`,
  );
  await goodCall(port);
});

test("corpus: preface then truncated frame header", async (t) => {
  const port = await startProxy(t);
  const bytes = Buffer.concat([Buffer.from(PREFACE), Buffer.from([0, 0, 5])]);
  await rawExchange(port, bytes, { endAfter: true });
  await goodCall(port);
});

test("corpus: DATA frame on an idle stream", async (t) => {
  const port = await startProxy(t);
  const bytes = Buffer.concat([
    Buffer.from(PREFACE),
    frameHeader(0, 0x4, 0, 0), // empty SETTINGS
    frameHeader(5, 0x0, 0, 1), // DATA on stream 1 (idle)
    Buffer.from("hello"),
  ]);
  const outcome = await rawExchange(port, bytes);
  assert.ok(
    outcome === "closed" || outcome === "goaway",
    `DATA on idle stream must error the connection, got ${outcome}`,
  );
  await goodCall(port);
});

test("corpus: unknown frame type and oversized declared frame", async (t) => {
  const port = await startProxy(t);
  const bytes = Buffer.concat([
    Buffer.from(PREFACE),
    frameHeader(0, 0x4, 0, 0),
    frameHeader(4, 0xff, 0, 0), // unknown type, must be ignored
    Buffer.from([1, 2, 3, 4]),
    frameHeader(0x7fffff, 0x3, 0, 3), // RST_STREAM claiming 8 MiB
    Buffer.from([0, 0, 0, 0]),
  ]);
  await rawExchange(port, bytes, { endAfter: true });
  await goodCall(port);
});

test("corpus: connect-and-destroy flood", async (t) => {
  const port = await startProxy(t);
  for (let i = 0; i < 5; i++) {
    await new Promise((resolve) => {
      const sock = net.connect(port, "127.0.0.1", () => {
        sock.write(Buffer.from(PREFACE));
        sock.destroy();
        resolve();
      });
      sock.on("error", () => resolve());
    });
  }
  await goodCall(port);
});

test("corpus: truncated LPM then end of stream", async (t) => {
  const port = await startProxy(t);
  const partial = Buffer.alloc(5 + 3);
  partial.writeUInt32BE(100, 1); // declares 100 bytes, sends 3
  const trailers = await hostileCall(port, { write: (s) => s.write(partial) });
  assert.notEqual(trailers["grpc-status"], "0", "truncated message must not succeed");
  await goodCall(port);
});

test("corpus: compressed flag with non-gzip bytes", async (t) => {
  const port = await startProxy(t);
  const framed = Buffer.alloc(5 + 8);
  framed[0] = 1;
  framed.writeUInt32BE(8, 1);
  framed.fill(0xab, 5);
  const trailers = await hostileCall(port, { write: (s) => s.write(framed) });
  assert.equal(trailers["grpc-status"], "12", "bad gzip must map to UNIMPLEMENTED");
  await goodCall(port);
});

test("corpus: unsupported grpc-encoding with compressed flag", async (t) => {
  const port = await startProxy(t);
  const payload = EchoRequest.encode(new EchoRequest({ message: "hello" }));
  const trailers = await hostileCall(port, {
    headers: { "grpc-encoding": "snappy" },
    write: (s) => {
      const framed = Buffer.alloc(5 + payload.length);
      framed[0] = 1;
      framed.writeUInt32BE(payload.length, 1);
      Buffer.from(payload).copy(framed, 5);
      s.write(framed);
    },
  });
  assert.equal(trailers["grpc-status"], "12", "snappy must map to UNIMPLEMENTED");
  await goodCall(port);
});

test("corpus: gzip output over the message cap", async (t) => {
  const port = await startProxy(t);
  // 32 MiB of zeros gzips to ~32 KiB; the decoder caps output
  // at MAX_MESSAGE (16 MiB) and must error, not allocate out.
  const packed = gzipSync(Buffer.alloc(32 * 1024 * 1024));
  const framed = Buffer.alloc(5 + packed.length);
  framed[0] = 1;
  framed.writeUInt32BE(packed.length, 1);
  packed.copy(framed, 5);
  const trailers = await hostileCall(port, {
    headers: { "grpc-encoding": "gzip" },
    write: (s) => s.write(framed),
  });
  assert.equal(trailers["grpc-status"], "12", "oversized decompression must error");
  await goodCall(port);
});

test("corpus: client destroys stream mid-message", async (t) => {
  const port = await startProxy(t);
  await withTimeout(
    new Promise((resolve) => {
      const session = http2.connect(`http://127.0.0.1:${port}`);
      const stream = session.request({
        ":path": "/echo.Echo/Unary",
        ":method": "POST",
        ":scheme": "http",
        "content-type": "application/grpc",
        te: "trailers",
      });
      stream.on("error", () => {});
      stream.write(Buffer.from([0, 0, 0]));
      setTimeout(() => {
        stream.destroy();
        session.close();
        resolve();
      }, 100);
    }),
    10000,
    "mid-message destroy",
  );
  await goodCall(port);
});

test("corpus: unary with no request message", async (t) => {
  const port = await startProxy(t);
  const trailers = await hostileCall(port, {});
  assert.notEqual(trailers["grpc-status"], "0", "missing request must not succeed");
  await goodCall(port);
});

test("corpus: well-formed call to an unknown path", async (t) => {
  const port = await startProxy(t);
  const payload = EchoRequest.encode(new EchoRequest({ message: "hello" }));
  const trailers = await hostileCall(port, {
    path: "/echo.Echo/Nope",
    write: (s) => s.write(lpm(payload)),
  });
  assert.equal(trailers["grpc-status"], "12", "unknown method must map to UNIMPLEMENTED");
  await goodCall(port);
});

test("corpus: LpmParser split and truncated inputs never throw early", () => {
  const parser = new LpmParser("identity");
  const payload = EchoRequest.encode(new EchoRequest({ message: "hello" }));
  const framed = lpm(payload);
  // Byte-at-a-time feeding must reassemble exactly one message.
  const out = [];
  for (const byte of framed) out.push(...parser.push(Buffer.from([byte])));
  assert.equal(out.length, 1);
  assert.deepEqual(Buffer.from(out[0]), Buffer.from(payload));
  // A declared length beyond the bytes fed is buffered, not an error.
  const partial = new LpmParser("identity");
  const head = Buffer.alloc(5);
  head.writeUInt32BE(0x00ffffff, 1);
  assert.deepEqual(partial.push(head), []);
  assert.deepEqual(partial.push(Buffer.from([1, 2, 3])), []);
});
