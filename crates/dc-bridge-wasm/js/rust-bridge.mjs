// JS host adapter for the Rust bridge core (dc-bridge-wasm):
// the same surface createGrpcDcBridge (js/src/wasm_bridge.js)
// returns — unary / serverStream / clientStream / bidi by
// path, protobuf bytes in/out — implemented by the Rust
// runtime compiled to Wasm instead of the JS runtime.
// Generated Wasm facades bind to this object unchanged.
//
//   import init, { BridgeCore } from "./pkg/dc_bridge_wasm.js";
//   await init(wasmBytes);
//   const bridge = createRustGrpcDcBridge(dc, BridgeCore);
//
// dc is an RTCDataChannel-shaped message pipe (send +
// message events), or a js/src Channel (its endpoint's
// DataChannel is used). options carry {metadata, timeout}
// and, for streaming calls, {cancelAfter: n} — identical
// semantics to the JS bridge.
export function createRustGrpcDcBridge(dc, BridgeCore) {
  const rawDc = dc && dc.endpoint ? dc.endpoint.dataChannel : dc;
  const transport = {
    send(u8) {
      rawDc.send(u8);
    },
    setOnMessage(cb) {
      const handler = (e) => {
        const d = e?.data ?? e;
        cb(d instanceof Uint8Array ? d : new Uint8Array(d));
      };
      if (typeof rawDc.addEventListener === "function") {
        rawDc.addEventListener("message", handler);
      } else {
        rawDc.onmessage = handler;
      }
    },
  };
  const core = new BridgeCore(transport);
  const meta = (options) => options?.metadata;
  const timeout = (options) => options?.timeout;
  const cancelAfter = (options) => options?.cancelAfter ?? 0;
  return {
    unary: (path, payload, options) =>
      core.unary(path, payload, meta(options), timeout(options)),
    serverStream: (path, payload, onMessage, options) =>
      core.server_stream(path, payload, onMessage, meta(options), timeout(options), cancelAfter(options)),
    clientStream: (path, payloads, options) =>
      core.client_stream(path, payloads, meta(options), timeout(options)),
    bidi: (path, payloads, onMessage, options) =>
      core.bidi(path, payloads, onMessage, meta(options), timeout(options), cancelAfter(options)),
  };
}
