// Worker host for the native Lua gRPC client (Lua 5.4 VM
// compiled to wasm32-wasi with EH-based setjmp). Same
// SharedArrayBuffer mailbox as the Zig native worker, plus
// hand-rolled wasi_snapshot_preview1 stubs — the Lua runtime
// only needs fd_write (print), clocks, and benign errors for
// the rest.

let sabI32 = null;
let sabBytes = null;
let instance = null;

const mem = () => new Uint8Array(instance.exports.memory.buffer);
const memView = () => new DataView(instance.exports.memory.buffer);
const readStr = (ptr, len) => new TextDecoder().decode(mem().subarray(ptr, ptr + len));

function wasiStubs() {
  const ERRNO_SUCCESS = 0, ERRNO_BADF = 8, ERRNO_NOENT = 44;
  return {
    fd_write(fd, iovs, iovsLen, nwrittenPtr) {
      const view = memView();
      let total = 0;
      let text = "";
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovs + i * 8, true);
        const len = view.getUint32(iovs + i * 8 + 4, true);
        text += readStr(ptr, len);
        total += len;
      }
      if (text) postMessage({ t: "log", text });
      view.setUint32(nwrittenPtr, total, true);
      return ERRNO_SUCCESS;
    },
    fd_read(fd, iovs, iovsLen, nreadPtr) {
      memView().setUint32(nreadPtr, 0, true);
      return ERRNO_SUCCESS;
    },
    fd_close: () => ERRNO_SUCCESS,
    fd_seek: () => ERRNO_SUCCESS,
    fd_renumber: () => ERRNO_SUCCESS,
    fd_fdstat_set_flags: () => ERRNO_SUCCESS,
    fd_fdstat_get(fd, resultPtr) {
      mem().fill(0, resultPtr, resultPtr + 24);
      return ERRNO_SUCCESS;
    },
    fd_prestat_get: () => ERRNO_BADF,
    fd_prestat_dir_name: () => ERRNO_BADF,
    path_open: () => ERRNO_NOENT,
    clock_time_get(id, precision, resultPtr) {
      memView().setBigUint64(resultPtr, BigInt(Date.now()) * 1000000n, true);
      return ERRNO_SUCCESS;
    },
    proc_exit(code) {
      throw { exitCode: code };
    },
    args_get: () => ERRNO_SUCCESS,
    args_sizes_get(argcPtr, argvBufSizePtr) {
      const view = memView();
      view.setUint32(argcPtr, 0, true);
      view.setUint32(argvBufSizePtr, 0, true);
      return ERRNO_SUCCESS;
    },
    environ_get: () => ERRNO_SUCCESS,
    environ_sizes_get(countPtr, sizePtr) {
      const view = memView();
      view.setUint32(countPtr, 0, true);
      view.setUint32(sizePtr, 0, true);
      return ERRNO_SUCCESS;
    },
  };
}

const env = {
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
  js_now_ms() {
    return Date.now();
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
    ({ instance } = await WebAssembly.instantiate(bytes, {
      env,
      wasi_snapshot_preview1: wasiStubs(),
    }));
    if (mode === "server") postMessage({ t: "ready" });
    instance.exports._start();
  } catch (err) {
    if (err && typeof err === "object" && "exitCode" in err) {
      if (err.exitCode !== 0) {
        postMessage({ t: "error", message: `lua exited with code ${err.exitCode}` });
      }
      return;
    }
    postMessage({ t: "error", message: String(err?.message ?? err) });
  }
};
