// DtlsConnection-compatible adapter over the shared
// Rust DTLS core compiled to Wasm (crates/dc-dtls-wasm):
// the same surface as ./dtls.js's DtlsConnection, Rust
// inside. Loading is async (Wasm instantiation), so hosts
// use the factory:
//
//   const { DtlsConnection } = await loadDtlsWasm(bytes);
//
// The core is sans-io; this adapter pumps it over the
// same packet io {send, recv} the mirrored stack drives.
import init, { Dtls } from "../../browser-test/dc_dtls_gen/dc_dtls_wasm.js";

const asBuffer = (u8) => Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength).slice();

function keyScalar(privateKey) {
  const jwk = privateKey.export({ format: "jwk" });
  return Buffer.from(jwk.d, "base64url");
}

function makeInner(role, config) {
  const cert = config.certificate;
  const args = [
    cert.der,
    keyScalar(cert.privateKey),
    config.expectedPeerFingerprint ?? null,
    config.requirePeerCertificate ?? false,
    config.connectionId ? Buffer.from(config.connectionId) : null,
    config.pairHint ? Buffer.from(config.pairHint) : null,
    Date.now(),
  ];
  return role === "client" ? Dtls.newClient(...args) : Dtls.newServer(...args);
}

async function pump(inner, io) {
  for (const packet of inner.start()) await io.send(asBuffer(packet));
  while (!inner.isEstablished) {
    const timeout = inner.nextTimeout(Date.now());
    if (timeout < 0) {
      throw new Error(`dtls handshake failed: ${inner.failure() || "unknown error"}`);
    }
    const packet = await io.recv(Math.max(0, Math.floor(timeout)));
    const out = packet
      ? inner.handleDatagram(packet, Date.now())
      : inner.tick(Date.now());
    for (const p of out) await io.send(asBuffer(p));
  }
}

class WasmDtlsConnection {
  #inner;
  #io;

  constructor(inner, io) {
    this.#inner = inner;
    this.#io = io;
  }

  static async connect(io, config) {
    const inner = makeInner("client", config);
    await pump(inner, io);
    return new WasmDtlsConnection(inner, io);
  }

  static async accept(io, config) {
    const inner = makeInner("server", config);
    await pump(inner, io);
    return new WasmDtlsConnection(inner, io);
  }

  peerFingerprint() {
    return this.#inner.peerFingerprint();
  }

  wasResumed() {
    return this.#inner.wasResumed;
  }

  async sendApp(data) {
    await this.#io.send(asBuffer(this.#inner.encryptApp(Buffer.from(data))));
  }

  async recvApp(timeoutMs = 60000) {
    const payload = await this.recvAppTimeout(timeoutMs);
    if (payload === null) throw new Error("timed out waiting for application data");
    return payload;
  }

  /** Returns null on timeout instead of throwing. */
  async recvAppTimeout(timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      const packet = await this.#io.recv(remaining);
      if (packet === null) return null;
      const payload = this.#inner.handleApp(packet);
      if (payload !== null) return asBuffer(payload);
    }
  }
}

export async function loadDtlsWasm(wasmBytes) {
  await init(wasmBytes);
  return { DtlsConnection: WasmDtlsConnection };
}
