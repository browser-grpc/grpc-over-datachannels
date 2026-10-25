// Proxy tests (ingress-first):
//  1. spec parity: generated mode table matches implementation
//  2. HTTP/2 ingress: stock HTTP/2 gRPC client -> proxy ->
//     grpc-dc Server over WebRTC-Direct (agent)

import assert from "node:assert/strict";
import http2 from "node:http2";
import { readFile } from "node:fs/promises";
import { createServer } from "node:net";
import test from "node:test";

import { EchoRequest, EchoResponse } from "../js/examples/echo_pb.js";
import { EchoClient } from "../js/examples/echo_grpc_dc.js";
import { LpmParser, lpm } from "../oracle/bridge.mjs";
import { dialDc, startIngressProxy } from "./grpc-dc-proxy.mjs";
import { startAgent } from "./grpc-dc-agent.mjs";

function freePort() {
  const probe = createServer();
  return new Promise((resolve) => {
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

test("proxy: generated mode table matches implementation", async () => {
  const spec = JSON.parse(await readFile(new URL("./proxy_modes.generated.json", import.meta.url), "utf8"));
  const byId = Object.fromEntries(spec.modes.map((m) => [m.id, m]));
  assert.equal(byId["http2-ingress"]?.status, "shipped");
  assert.deepEqual(Object.keys(byId), ["http2-ingress"], "proxy supports only HTTP/2 over TCP");
  assert.equal(byId["dc-egress"], undefined, "egress direction was removed");
  const proxySource = await readFile(new URL("./grpc-dc-proxy.mjs", import.meta.url), "utf8");
  assert.match(proxySource, /serveHttp2ToDc/, "http2-ingress must use the bridge server");
  assert.doesNotMatch(proxySource, /TcpFramedChannel|--tcp/, "custom TCP ingress was removed");
  assert.match(proxySource, /directClientStackEndpoint/, "DC leg must dial WebRTC-Direct");
  assert.doesNotMatch(proxySource, /serveDcToHttp2|startEgressProxy/, "egress direction was removed");
});

// Raw HTTP/2 gRPC client call against the ingress listener.
function http2Call(port, path, payload) {
  return new Promise((resolve, reject) => {
    const session = http2.connect(`http://127.0.0.1:${port}`);
    const stream = session.request({
      ":path": path,
      ":method": "POST",
      ":scheme": "http",
      "content-type": "application/grpc",
      te: "trailers",
    });
    const parser = new LpmParser("identity");
    const messages = [];
    let trailers = null;
    stream.on("data", (chunk) => messages.push(...parser.push(chunk)));
    stream.on("trailers", (t) => (trailers = t));
    stream.on("error", reject);
    stream.on("end", () => {
      session.close();
      resolve({ messages, trailers });
    });
    stream.end(lpm(payload));
  });
}

async function startIngress(t) {
  const agent = await startAgent({});
  t.after(() => agent.close());
  const dc = await dialDc(agent.multiaddr);
  const proxy = await startIngressProxy({
    dcStackEndpoint: dc.endpoint,
    dc,
    http2Port: await freePort(),
  });
  t.after(() => proxy.close());
  return proxy;
}

test("proxy ingress http2: stock HTTP/2 client -> proxy -> grpc-dc server (WebRTC-Direct)", { timeout: 120000 }, async (t) => {
  const proxy = await startIngress(t);

  const unary = await http2Call(
    proxy.http2Port,
    "/echo.Echo/Unary",
    EchoRequest.encode(new EchoRequest({ message: "hello" })),
  );
  assert.equal(unary.trailers["grpc-status"], "0");
  assert.equal(EchoResponse.decode(unary.messages[0]).message, "echo: hello");

  const stream = await http2Call(
    proxy.http2Port,
    "/echo.Echo/ServerStream",
    EchoRequest.encode(new EchoRequest({ message: "tick", count: 3 })),
  );
  assert.deepEqual(
    stream.messages.map((m) => EchoResponse.decode(m).index),
    [0, 1, 2],
  );

  const fail = await http2Call(
    proxy.http2Port,
    "/echo.Echo/Unary",
    EchoRequest.encode(new EchoRequest({ message: "fail" })),
  );
  assert.equal(fail.trailers["grpc-status"], "3");
});
