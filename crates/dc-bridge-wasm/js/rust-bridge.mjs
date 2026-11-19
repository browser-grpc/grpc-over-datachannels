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
function transportOf(dc) {
  const rawDc = dc && dc.endpoint ? dc.endpoint.dataChannel : dc;
  return {
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
}

export function createRustGrpcDcBridge(dc, BridgeCore) {
  const core = new BridgeCore(transportOf(dc));
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

// Server mirror: register JS handlers by path; the Rust
// runtime owns the wire. Handler shapes match the JS server
// bridge (js/src/wasm_bridge.js): unary (req, metaPairs) ->
// Promise<bytes>; serverStream (req, metaPairs, onMessage);
// clientStream (payloads, metaPairs) -> Promise<bytes>;
// bidi (payloads, metaPairs, onMessage). Failures thrown as
// {code, message} cross back as that status.
export function createRustGrpcDcServerBridge(dc, BridgeServer) {
  const server = new BridgeServer(transportOf(dc));
  return {
    registerUnary: (path, handler) => server.registerUnary(path, handler),
    registerServerStream: (path, handler) =>
      server.registerServerStream(path, handler),
    registerClientStream: (path, handler) =>
      server.registerClientStream(path, handler),
    registerBidi: (path, handler) => server.registerBidi(path, handler),
    registerClientStreamInc: (path, handler) =>
      server.registerClientStreamInc(path, handler),
    registerBidiInc: (path, handler) => server.registerBidiInc(path, handler),
    start: (serviceName) => server.start(serviceName),
  };
}
