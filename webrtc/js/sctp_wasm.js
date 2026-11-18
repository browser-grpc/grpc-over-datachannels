// Association-compatible adapter over the shared Rust
// SCTP core compiled to Wasm (crates/dc-sctp-wasm): the
// same surface as ./sctp.js's Association, Rust inside.
// Loading is async (Wasm instantiation), so hosts use the
// factory:
//
//   const { Association } = await loadSctpWasm(wasmBytes);
//
// Conformance: test/sctp_wasm_vectors.test.js runs the
// shared fixtures against this adapter.
import init, { SctpAssoc } from "../../browser-test/dc_sctp_gen/dc_sctp_wasm.js";

export const SCTP_PORT = 5000;

const asBuffer = (u8) => Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength).slice();

function mapResult({ packets, events }) {
  return {
    packets: packets.map(asBuffer),
    events: events.map((e) =>
      e.type === "data" ? { ...e, payload: asBuffer(e.payload) } : e
    ),
  };
}

class WasmAssociation {
  #inner;

  constructor(inner) {
    this.#inner = inner;
  }

  static newClient(localPort = SCTP_PORT, peerPort = SCTP_PORT) {
    return new WasmAssociation(SctpAssoc.newClient(localPort, peerPort));
  }

  static newServer(localPort = SCTP_PORT, peerPort = SCTP_PORT) {
    return new WasmAssociation(SctpAssoc.newServer(localPort, peerPort));
  }

  get isEstablished() {
    return this.#inner.isEstablished;
  }

  connect(nowMs) {
    return asBuffer(this.#inner.connect(nowMs));
  }

  sendData(stream, ppid, payload, opts = {}, nowMs = 0) {
    const packets = this.#inner.sendData(
      stream,
      ppid,
      payload,
      opts.unordered ?? false,
      opts.maxRetransmits ?? -1,
      opts.maxLifetimeMs ?? -1,
      nowMs
    );
    return packets.map(asBuffer);
  }

  handlePacket(packet, nowMs) {
    return mapResult(this.#inner.handlePacket(packet, nowMs));
  }

  tick(nowMs) {
    return mapResult(this.#inner.tick(nowMs));
  }

  stats() {
    const [packetsSent, packetsReceived, chunksSent, chunksReceived, retransmits, fastRetransmits, dupChunks] =
      this.#inner.stats();
    return {
      packetsSent,
      packetsReceived,
      chunksSent,
      chunksReceived,
      retransmits,
      fastRetransmits,
      dupChunks,
    };
  }

  closeStream(stream) {
    return this.#inner.closeStream(stream).map(asBuffer);
  }

  close(nowMs) {
    return this.#inner.close(nowMs).map(asBuffer);
  }
}

/// Instantiate the Wasm core and return the
/// Association-compatible surface ({ Association, SCTP_PORT }).
export async function loadSctpWasm(wasmBytes) {
  await init(wasmBytes);
  return { Association: WasmAssociation, SCTP_PORT };
}
