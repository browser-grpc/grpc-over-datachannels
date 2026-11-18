// Interop smoke: Rust-wasm bridge core (client) <-> JS
// runtime (server) over an in-memory DataChannel pair,
// driven through the JS host adapter (js/rust-bridge.mjs) at
// exactly the facade boundary (paths + protobuf bytes).
//
// Prereq: wasm-pack build --release --target web --out-dir pkg
// Run:    node test/smoke.mjs
import { readFileSync } from "node:fs";
import init, { BridgeCore } from "../pkg/dc_bridge_wasm.js";
import { createRustGrpcDcBridge } from "../js/rust-bridge.mjs";
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
const dec = (bytes) => EchoResponse.decode(bytes);
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

console.log("SMOKE OK");
process.exit(0);
