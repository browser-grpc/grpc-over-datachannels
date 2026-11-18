// IceAgent-compatible adapter over the shared Rust ICE
// core compiled to Wasm (crates/dc-ice-wasm): the same
// field/method surface as ./ice.js's IceAgent, Rust
// inside. Loading is async (Wasm instantiation), so hosts
// use the factory:
//
//   const { IceAgent } = await loadIceWasm(wasmBytes);
//
// The public fields stay JS-side mirrors (peer.js reads
// and pushes them directly); every method syncs pending
// changes into the core first, and core-owned state
// (nomination, generation) is read back, never shadowed.
import init, { Ice } from "../../browser-test/dc_ice_gen/dc_ice_wasm.js";
import { Candidate } from "./candidate.js";

const asBuffer = (u8) => Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength).slice();

function parseAddr(addr) {
  // "127.0.0.1:5000" or "[::1]:5000"
  const idx = addr.lastIndexOf(":");
  const host = addr.startsWith("[") ? addr.slice(1, idx - 1) : addr.slice(0, idx);
  return { address: host, port: Number(addr.slice(idx + 1)) };
}

function formatAddr({ address, port }) {
  return address.includes(":") ? `[${address}]:${port}` : `${address}:${port}`;
}

class WasmIceAgent {
  #inner;
  #syncedUfrag;
  #syncedPwd;
  #pushedLocal = 0;
  #pushedRemote = new Set();

  constructor(controlling) {
    this.#inner = new Ice(controlling);
    this.localUfrag = this.#inner.localUfrag;
    this.localPwd = this.#inner.localPwd;
    this.#syncedUfrag = this.localUfrag;
    this.#syncedPwd = this.localPwd;
    this.remoteUfrag = "";
    this.remotePwd = "";
    this.localCandidates = [];
    this.remoteCandidates = [];
    this.nominated = null;
  }

  get controlling() {
    return this.#inner.controlling;
  }

  set controlling(value) {
    this.#inner.setControlling(value);
  }

  get generation() {
    return this.#inner.generation;
  }

  get renominated() {
    return this.#inner.renominated;
  }

  #sync() {
    this.#inner.setTime(Date.now());
    if (this.localUfrag !== this.#syncedUfrag || this.localPwd !== this.#syncedPwd) {
      this.#inner.setLocalCredentials(this.localUfrag, this.localPwd);
      this.#syncedUfrag = this.localUfrag;
      this.#syncedPwd = this.localPwd;
    }
    for (; this.#pushedLocal < this.localCandidates.length; this.#pushedLocal++) {
      this.#inner.addLocalCandidate(this.localCandidates[this.#pushedLocal].toSdp());
    }
    for (const cand of this.remoteCandidates) {
      if (!this.#pushedRemote.has(cand.key)) {
        this.#inner.addRemoteCandidate(cand.toSdp());
        this.#pushedRemote.add(cand.key);
      }
    }
  }

  #refreshNominated() {
    const addr = this.#inner.nominated;
    if (!addr) {
      this.nominated = null;
      return;
    }
    const { address, port } = parseAddr(addr);
    this.nominated =
      this.remoteCandidates.find((c) => c.address === address && c.port === port) ??
      Candidate.host(address, port, "peer-reflexive");
  }

  #remoteFor(addr) {
    const { address, port } = parseAddr(addr);
    return (
      this.remoteCandidates.find((c) => c.address === address && c.port === port) ??
      Candidate.host(address, port, "peer-reflexive")
    );
  }

  restart() {
    this.#inner.restart();
    this.localUfrag = this.#inner.localUfrag;
    this.localPwd = this.#inner.localPwd;
    this.#syncedUfrag = this.localUfrag;
    this.#syncedPwd = this.localPwd;
  }

  setRemote(ufrag, pwd, candidates) {
    this.remoteUfrag = ufrag;
    this.remotePwd = pwd;
    this.remoteCandidates = candidates;
    this.#inner.setRemote(ufrag, pwd);
    this.#pushedRemote = new Set();
    this.#sync();
  }

  addRemoteCandidate(cand) {
    if (this.remoteCandidates.some((c) => c.key === cand.key)) return false;
    this.remoteCandidates.push(cand);
    this.#sync();
    return true;
  }

  dueChecks() {
    this.#sync();
    return this.#inner.dueChecks().map(({ bytes, addr }) => ({
      bytes: asBuffer(bytes),
      remote: this.#remoteFor(addr),
    }));
  }

  handleStun(raw, src) {
    this.#sync();
    const { responses, events } = this.#inner.handleStun(raw, formatAddr(src));
    this.#refreshNominated();
    return {
      responses: responses.map(({ bytes, addr }) => ({
        bytes: asBuffer(bytes),
        remote: this.#remoteFor(addr),
      })),
      events: events.map(({ kind, addr }) => ({
        type: kind === 2 ? "nominated" : "pair-valid",
        remote: this.#remoteFor(addr),
      })),
    };
  }

  consentCheck() {
    this.#sync();
    const check = this.#inner.consentCheck();
    if (!check) return null;
    return { bytes: asBuffer(check.bytes), remote: this.#remoteFor(check.addr) };
  }

  touchConsent() {
    this.#sync();
    this.#inner.touchConsent();
  }

  consentExpired(expiryMs) {
    this.#inner.setTime(Date.now());
    return this.#inner.consentExpired(expiryMs);
  }
}

export async function loadIceWasm(wasmBytes) {
  await init(wasmBytes);
  return { IceAgent: WasmIceAgent };
}
