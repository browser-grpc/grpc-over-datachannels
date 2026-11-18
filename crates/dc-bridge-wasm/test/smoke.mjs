// Interop smoke: Rust-wasm bridge core (client) <-> JS
// runtime (server) over an in-memory DataChannel pair,
// driven through the JS host adapter (js/rust-bridge.mjs) at
// exactly the facade boundary (paths + protobuf bytes).
//
// Prereq: wasm-pack build --release --target web --out-dir pkg
// Run:    node test/smoke.mjs
import { readFileSync } from "node:fs";
import init, { BridgeCore, BridgeServer } from "../pkg/dc_bridge_wasm.js";
import {
  createRustGrpcDcBridge,
  createRustGrpcDcServerBridge,
} from "../js/rust-bridge.mjs";
import { Server, StatusCode, StatusError } from "../../../js/index.js";
import { memoryDataChannelPair } from "../../../js/src/loopback.js";
import { EchoRequest, EchoResponse } from "../../../js/examples/echo_pb.js";
import { createEchoService } from "../../../js/examples/echo_grpc_dc.js";

await init(readFileSync(new URL("../pkg/dc_bridge_wasm_bg.wasm", import.meta.url)));

const [a, b] = memoryDataChannelPair();
const server = new Server();
server.addService(
  createEchoService({
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
  })
);
server.serve(b);

const bridge = createRustGrpcDcBridge(a, BridgeCore);
const enc = (msg) => EchoRequest.encode(msg);
const encResp = (msg) => EchoResponse.encode(msg);
const dec = (bytes) => EchoResponse.decode(bytes);
const decReq = (bytes) => EchoRequest.decode(bytes);
const req = (message, count = 0) => enc(new EchoRequest({ message, count }));

const r1 = dec(await bridge.unary("/echo.Echo/Unary", req("hello")));
console.log("unary:", r1.message);
if (r1.message !== "echo: hello") throw new Error("unary mismatch");

try {
  await bridge.unary("/echo.Echo/Unary", req("fail"));
  throw new Error("unary-fail did not reject");
} catch (e) {
  console.log("unary-fail code:", e.code, "msg:", e.message);
  if (e.code !== 3) throw new Error("want INVALID_ARGUMENT=3");
}

const ticks = [];
await bridge.serverStream("/echo.Echo/ServerStream", req("tick", 3), (bytes) =>
  ticks.push(dec(bytes).index)
);
console.log("serverStream indexes:", ticks.join(","));
if (ticks.join(",") !== "0,1,2") throw new Error("serverStream mismatch");

const ticks2 = [];
await bridge.serverStream(
  "/echo.Echo/ServerStream",
  req("tick", 5),
  (bytes) => ticks2.push(dec(bytes).index),
  { cancelAfter: 2 }
);
console.log("serverStream cancelAfter=2 got:", ticks2.join(","));
if (ticks2.join(",") !== "0,1") throw new Error("cancelAfter mismatch");

const joined = dec(
  await bridge.clientStream("/echo.Echo/ClientStream", [req("a"), req("b")])
);
console.log("clientStream:", joined.message);
if (joined.message !== "a+b") throw new Error("clientStream mismatch");

const echoed = [];
await bridge.bidi("/echo.Echo/Bidi", [req("x"), req("y")], (bytes) =>
  echoed.push(dec(bytes).message)
);
console.log("bidi:", echoed.join(","));
if (echoed.join(",") !== "x,y") throw new Error("bidi mismatch");

// --- server bridge: JS handlers served by the Rust core ---
const [c, d] = memoryDataChannelPair();
const echoServer = createRustGrpcDcServerBridge(d, BridgeServer);
echoServer.registerUnary("/echo.Echo/Unary", async (bytes) => {
  const r = decReq(bytes);
  if (r.message === "fail") throw { code: 3, message: "asked to fail" };
  return encResp(new EchoResponse({ message: `echo: ${r.message}`, index: 0 }));
});
echoServer.registerServerStream("/echo.Echo/ServerStream", async (bytes, _meta, onMessage) => {
  const r = decReq(bytes);
  for (let i = 0; i < Math.max(0, r.count); i++) {
    onMessage(encResp(new EchoResponse({ message: r.message, index: i })));
  }
});
echoServer.registerClientStream("/echo.Echo/ClientStream", async (payloads) => {
  const parts = payloads.map((p) => decReq(p).message);
  return encResp(new EchoResponse({ message: parts.join("+"), index: parts.length }));
});
echoServer.registerBidi("/echo.Echo/Bidi", async (payloads, _meta, onMessage) => {
  let index = 0;
  for (const p of payloads) {
    onMessage(encResp(new EchoResponse({ message: decReq(p).message, index: index++ })));
  }
});
echoServer.start("echo.Echo");

const client2 = createRustGrpcDcBridge(c, BridgeCore);
const s1 = dec(await client2.unary("/echo.Echo/Unary", req("hello")));
console.log("server-bridge unary:", s1.message);
if (s1.message !== "echo: hello") throw new Error("server-bridge unary mismatch");
try {
  await client2.unary("/echo.Echo/Unary", req("fail"));
  throw new Error("server-bridge unary-fail did not reject");
} catch (e) {
  console.log("server-bridge unary-fail code:", e.code);
  if (e.code !== 3) throw new Error("want code 3");
}
const sticks = [];
await client2.serverStream("/echo.Echo/ServerStream", req("tick", 3), (bytes) =>
  sticks.push(dec(bytes).index)
);
console.log("server-bridge serverStream:", sticks.join(","));
if (sticks.join(",") !== "0,1,2") throw new Error("server-bridge stream mismatch");
const sjoined = dec(await client2.clientStream("/echo.Echo/ClientStream", [req("a"), req("b")]));
console.log("server-bridge clientStream:", sjoined.message);
if (sjoined.message !== "a+b") throw new Error("server-bridge clientStream mismatch");
const sechoed = [];
await client2.bidi("/echo.Echo/Bidi", [req("x"), req("y")], (bytes) =>
  sechoed.push(dec(bytes).message)
);
console.log("server-bridge bidi:", sechoed.join(","));
if (sechoed.join(",") !== "x,y") throw new Error("server-bridge bidi mismatch");

// --- incremental server handlers (pull-based source) ---
const [e, f] = memoryDataChannelPair();
const incServer = createRustGrpcDcServerBridge(f, BridgeServer);
incServer.registerClientStreamInc("/echo.Echo/ClientStream", async (source) => {
  const parts = [];
  let bytes;
  while ((bytes = await source.next()) !== null) parts.push(decReq(bytes).message);
  return encResp(new EchoResponse({ message: parts.join("+"), index: parts.length }));
});
incServer.registerBidiInc("/echo.Echo/Bidi", async (source, _meta, onMessage) => {
  let bytes;
  let index = 0;
  while ((bytes = await source.next()) !== null) {
    onMessage(encResp(new EchoResponse({ message: decReq(bytes).message, index: index++ })));
  }
});
incServer.start("echo.Echo");

const client3 = createRustGrpcDcBridge(e, BridgeCore);
const ijoined = dec(await client3.clientStream("/echo.Echo/ClientStream", [req("a"), req("b")]));
console.log("inc clientStream:", ijoined.message);
if (ijoined.message !== "a+b") throw new Error("inc clientStream mismatch");
const iechoed = [];
await client3.bidi("/echo.Echo/Bidi", [req("x"), req("y")], (bytes) =>
  iechoed.push(dec(bytes).message)
);
console.log("inc bidi:", iechoed.join(","));
if (iechoed.join(",") !== "x,y") throw new Error("inc bidi mismatch");

console.log("SMOKE OK");
process.exit(0);
