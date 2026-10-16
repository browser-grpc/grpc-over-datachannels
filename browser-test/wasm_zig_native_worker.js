// Worker host for the native Zig/WASM gRPC client. The page
// owns the RTCDataChannel and a SharedArrayBuffer mailbox
// (Int32 [state, len] header + payload at byte offset 8):
// inbound messages are written there by the page; this
// worker's js_dc_recv Atomics.wait()s on it, so the blocking
// native Zig client code can run to completion on this
// thread while the page thread stays event-driven.

let sabI32 = null;
let sabBytes = null;
let instance = null;

const mem = () => new Uint8Array(instance.exports.memory.buffer);
const readStr = (ptr, len) => new TextDecoder().decode(mem().subarray(ptr, ptr + len));

const env = {
  js_now_ms() {
    return performance.now();
  },
  js_dc_send(ptr, len) {
    postMessage({ t: "send", bytes: mem().slice(ptr, ptr + len) });
  },
  // Returns message length, -1 on timeout, -2 when closed.
  js_dc_recv(ptr, cap, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const state = Atomics.load(sabI32, 0);
      if (state === 1) {
        const len = Math.min(sabI32[1], cap);
        mem().set(sabBytes.subarray(8, 8 + len), ptr);
        Atomics.store(sabI32, 0, 0);
        Atomics.notify(sabI32, 0);
        return len;
      }
      if (state === 2) return -2;
      const remaining = deadline - Date.now();
      if (remaining <= 0) return -1;
      Atomics.wait(sabI32, 0, 0, remaining);
    }
  },
  on_result(ptr, len) {
    postMessage({ t: "result", json: readStr(ptr, len) });
  },
  on_error(ptr, len) {
    postMessage({ t: "error", message: readStr(ptr, len) });
  },
};

onmessage = async (event) => {
  const { sab, wasmUrl, mode } = event.data;
  sabI32 = new Int32Array(sab);
  sabBytes = new Uint8Array(sab);
  try {
    const bytes = await (await fetch(wasmUrl)).arrayBuffer();
    ({ instance } = await WebAssembly.instantiate(bytes, { env }));
    if (mode === "server") {
      postMessage({ t: "ready" });
      instance.exports.run_echo_server();
      // run_echo_server never returns (inline pump loop).
      return;
    }
    instance.exports.run_echo_client();
    // run_echo_client only returns after reporting via
    // on_result/on_error (or never, if the peer stalls and
    // the test times out at the page level).
  } catch (err) {
    postMessage({ t: "error", message: String(err?.message ?? err) });
  }
};
