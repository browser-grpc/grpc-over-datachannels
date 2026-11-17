// HTTP/2 leg counters for LinkStats (JS): Http2DataChannel
// counts translated HEADERS/DATA frames and opened streams
// over a node:http2 session; channel.http2Stats exposes the
// snapshot. The server is a minimal node:http2 gRPC-shaped
// responder (headers, one empty message, trailers).

import assert from "node:assert/strict";
import http2 from "node:http2";
import test from "node:test";

import { FrameType, encodeFrame } from "../src/codec.js";
import { Http2DataChannel, http2Channel } from "../src/http2.js";

test("http2 stats fill on a live call", async (t) => {
  const server = http2.createServer();
  server.on("stream", (stream) => {
    stream.respond({
      ":status": 200,
      "content-type": "application/grpc",
      "grpc-accept-encoding": "gzip,identity",
    });
    // One empty gRPC message (LPM: flag 0 + len 0) + trailers.
    stream.end(Buffer.from([0, 0, 0, 0, 0]));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());
  const port = server.address().port;

  const dc = new Http2DataChannel(`127.0.0.1:${port}`);
  t.after(() => dc.close());
  const frames = [];
  dc.addEventListener("message", (e) => frames.push(new Uint8Array(e.data)));
  dc.send(encodeFrame(FrameType.HEADERS, 1, new TextEncoder().encode(
    JSON.stringify({ path: "/echo.Echo/Unary", metadata: {} }),
  )));
  dc.send(encodeFrame(FrameType.DATA, 1, new Uint8Array(0)));
  dc.send(encodeFrame(FrameType.HALF_CLOSE, 1, new Uint8Array(0)));
  const deadline = Date.now() + 10000;
  while (frames.length < 2 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 25));
  }
  assert.ok(frames.length >= 1, "no response frames");
  const stats = dc.stats();
  assert.equal(stats.streamsOpened, 1);
  assert.ok(stats.framesSent >= 2, JSON.stringify(stats));
  assert.ok(stats.framesReceived >= 1, JSON.stringify(stats));

  const channel = http2Channel(`127.0.0.1:${port}`);
  t.after(() => channel.endpoint.dataChannel.close());
  assert.equal(typeof channel.http2Stats, "function");
  assert.equal(channel.http2Stats().streamsOpened, 0);
});
