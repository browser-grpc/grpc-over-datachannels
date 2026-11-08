// Worker host for the native Kotlin gRPC client (real grpcdc
// runtime compiled to Kotlin/Wasm). Same SharedArrayBuffer
// mailbox as the Swift/Zig/Lua/C++ native workers (Int32
// [state, len] header + payload at byte offset 8): the Kotlin
// DcTransport Atomics.wait()s on it, so the blocking native
// client code can run to completion on this thread while the
// page stays event-driven. performance.now (via the runtime's
// grpcdcNowNanos) backs deadlines/timeouts.

onmessage = async (event) => {
  const { sab, wasmUrl, mode } = event.data;
  try {
    const mod = await import(wasmUrl);
    if (mode === "tracing") {
      const json = mod.runEchoTracingNative();
      postMessage({ t: "result", json });
      return;
    }
    if (mode === "server") {
      postMessage({ t: "ready" });
      mod.runEchoServerNative(sab);
      // runEchoServerNative never returns (inline pump loop).
      return;
    }
    if (mode === "server-tracing") {
      postMessage({ t: "ready" });
      mod.runEchoServerTracingNative(sab);
      // Tracing spans report via result messages while pumping.
      return;
    }
    if (mode === "client-tracing") {
      const json = mod.runEchoClientTracingNative(sab);
      postMessage({ t: "result", json });
      return;
    }
    const json = mod.runEchoClientNative(sab);
    postMessage({ t: "result", json });
  } catch (err) {
    postMessage({ t: "error", message: String((err && err.message) || err) });
  }
};
