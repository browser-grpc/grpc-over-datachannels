// libp2p-style WebRTC-Direct: signaling-free client->server
// connections over DTLS + SCTP datachannels (Node).
//
// The listener owns a UDP socket and a self-signed certificate.
// Its identity is the certificate hash ("certhash": multibase
// base64url of the sha2-256 multihash of the cert DER), as in
// libp2p multiaddrs:
//   /ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/f...
//
// The dialer needs only the address and certhash: it starts a
// DTLS handshake directly over UDP (no ICE, no SDP exchange --
// roles are fixed: dialer is DTLS client, listener is DTLS
// server), pinned to the certhash. `directDialTurn` is the
// symmetric-NAT path: all DTLS datagrams ride a TURN allocation
// (Send/Data indications or ChannelData), so the dialer never
// exchanges a direct packet with the listener.
//
// Browsers cannot bind UDP or allocate TURN this way; the
// browser dialer lives in the grpc-dc JS runtime and uses a
// native RTCPeerConnection with relay-only ICE (see SPEC-WEBRTC).

import dgram from "node:dgram";
import { DtlsConnection, sha256, udpPacketIo } from "./dtls.js";
import { DcEndpoint } from "./endpoint.js";
import { StunMessage } from "./stun.js";
import { StunMessageType } from "./proto_gen.js";
import {
  allocateTurn,
  bindChannels,
  createPermissions,
  unwrapChannelData,
  unwrapDataIndication,
  wrapChannelData,
  wrapSendIndication,
} from "./turn.js";
import { Certificate } from "./x509.js";

// ---------------------------------------------------------------------------
// certhash (multibase base64url of multihash sha2-256 of cert DER)
// ---------------------------------------------------------------------------

export function certhashOfCert(cert) {
  const digest = sha256(Buffer.from(cert.der));
  const mh = Buffer.concat([Buffer.from([0x12, 0x20]), digest]);
  return `f${mh.toString("base64url")}`;
}

export function parseCerthash(s) {
  if (typeof s !== "string" || !s.startsWith("f")) return null;
  let mh;
  try {
    mh = Buffer.from(s.slice(1), "base64url");
  } catch {
    return null;
  }
  if (mh.length !== 34 || mh[0] !== 0x12 || mh[1] !== 0x20) return null;
  return Buffer.from(mh.subarray(2));
}

export function fingerprintOfDigest(digest) {
  return [...digest].map((b) => b.toString(16).padStart(2, "0").toUpperCase()).join(":");
}

function certhashOfDigest(digest) {
  const mh = Buffer.concat([Buffer.from([0x12, 0x20]), digest]);
  return `f${mh.toString("base64url")}`;
}

// ---------------------------------------------------------------------------
// multiaddr (the /webrtc-direct subset)
// ---------------------------------------------------------------------------

export function parseDirectMultiaddr(s) {
  const parts = String(s).split("/").filter(Boolean);
  if (
    parts.length !== 7 ||
    parts[2] !== "udp" ||
    parts[4] !== "webrtc-direct" ||
    parts[5] !== "certhash"
  ) {
    return null;
  }
  if (parts[0] !== "ip4" && parts[0] !== "ip6") return null;
  const port = Number(parts[3]);
  if (!Number.isInteger(port) || port < 0 || port > 65535) return null;
  const digest = parseCerthash(parts[6]);
  if (!digest) return null;
  return { remote: { address: parts[1], port }, digest };
}

export function directMultiaddr(address, port, certhash) {
  const family = String(address).includes(":") ? "ip6" : "ip4";
  return `/${family}/${address}/udp/${port}/webrtc-direct/certhash/${certhash}`;
}

// ---------------------------------------------------------------------------
// packet IO helpers
// ---------------------------------------------------------------------------

// DTLS packet IO for one claimed peer of a DirectListener.
class DirectPeerIo {
  constructor(socket, peer) {
    this.socket = socket;
    this.peer = peer;
    this.queue = [];
    this.waiters = [];
  }

  deliver(msg) {
    const waiter = this.waiters.shift();
    if (waiter) waiter(msg);
    else this.queue.push(msg);
  }

  send(buf) {
    return new Promise((resolve, reject) => {
      this.socket.send(buf, this.peer.port, this.peer.address, (e) =>
        e ? reject(e) : resolve(),
      );
    });
  }

  recv(timeoutMs) {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    return new Promise((resolve) => {
      const waiter = (msg) => {
        clearTimeout(timer);
        resolve(msg);
      };
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i >= 0) this.waiters.splice(i, 1);
        resolve(null);
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }
}

function clientConfig(certificate, digest) {
  return {
    certificate,
    expectedPeerFingerprint: fingerprintOfDigest(digest),
    requirePeerCertificate: true,
  };
}

function serverConfig(certificate) {
  return {
    certificate,
    expectedPeerFingerprint: null,
    requirePeerCertificate: false,
  };
}

const bindSocket = (family, port, address) =>
  new Promise((resolve, reject) => {
    const socket = dgram.createSocket(family);
    socket.once("error", reject);
    socket.bind(port, address, () => resolve(socket));
  });

// ---------------------------------------------------------------------------
// listener + dialer
// ---------------------------------------------------------------------------

export class DirectListener {
  constructor(socket, certificate) {
    this.socket = socket;
    this.certificate = certificate;
    // One socket, many peers: a single message handler routes
    // datagrams by sender to the endpoint that claimed that
    // peer; unclaimed peers queue until an accept claims them.
    // Without this, concurrent dialers would steal each
    // other's handshake packets.
    this.routes = new Map();
    this.pending = new Map();
    this.pendingOrder = [];
    this.claimWaiters = [];
    socket.on("message", (msg, rinfo) => this._onPacket(msg, rinfo));
  }

  _onPacket(msg, rinfo) {
    const key = `${rinfo.address}:${rinfo.port}`;
    const route = this.routes.get(key);
    if (route) {
      route.deliver(msg);
      return;
    }
    let entry = this.pending.get(key);
    if (!entry) {
      entry = { peer: { address: rinfo.address, port: rinfo.port }, queue: [] };
      this.pending.set(key, entry);
      this.pendingOrder.push(key);
      const waiters = this.claimWaiters.splice(0);
      for (const wake of waiters) wake();
    }
    entry.queue.push(msg);
  }

  async _claim() {
    while (this.pendingOrder.length === 0) {
      await new Promise((resolve) => this.claimWaiters.push(resolve));
    }
    const key = this.pendingOrder.shift();
    const entry = this.pending.get(key);
    this.pending.delete(key);
    const io = new DirectPeerIo(this.socket, entry.peer);
    for (const msg of entry.queue) io.deliver(msg);
    this.routes.set(key, io);
    return { key, io };
  }

  static async bind({ address = "127.0.0.1", port = 0, certificate = Certificate.generate() } = {}) {
    const v6 = String(address).includes(":");
    const socket = await bindSocket(v6 ? "udp6" : "udp4", port, address);
    return new DirectListener(socket, certificate);
  }

  get address() {
    return this.socket.address();
  }

  certhash() {
    return certhashOfCert(this.certificate);
  }

  multiaddr() {
    const { address, port } = this.socket.address();
    return directMultiaddr(address, port, this.certhash());
  }

  // Accept one direct connection (DTLS accept) and return its
  // datachannel endpoint. Call again for the next dialer.
  async accept() {
    const { key, io } = await this._claim();
    try {
      const dtls = await DtlsConnection.accept(io, serverConfig(this.certificate));
      return new DcEndpoint(dtls, "server");
    } catch (err) {
      this.routes.delete(key);
      throw err;
    }
  }

  close() {
    try {
      this.socket.close();
    } catch {}
  }
}

function withTransportClose(endpoint, closeFn) {
  endpoint.closeDirect = async () => {
    await endpoint.close().catch(() => {});
    closeFn();
  };
  return endpoint;
}

export async function directDial(remote, certhash, { certificate = Certificate.generate() } = {}) {
  const digest = parseCerthash(certhash);
  if (!digest) throw new Error("bad certhash");
  const v6 = String(remote.address).includes(":");
  const socket = await bindSocket(v6 ? "udp6" : "udp4", 0, v6 ? "::" : "0.0.0.0");
  try {
    const dtls = await DtlsConnection.connect(
      udpPacketIo(socket, remote),
      clientConfig(certificate, digest),
    );
    return withTransportClose(new DcEndpoint(dtls, "client"), () => {
      try {
        socket.close();
      } catch {}
    });
  } catch (err) {
    try {
      socket.close();
    } catch {}
    throw err;
  }
}

export async function directDialMultiaddr(multiaddr, opts = {}) {
  const parsed = parseDirectMultiaddr(multiaddr);
  if (!parsed) throw new Error("bad direct multiaddr");
  return directDial(parsed.remote, certhashOfDigest(parsed.digest), opts);
}

// ---------------------------------------------------------------------------
// dial over TURN (symmetric-NAT path)
// ---------------------------------------------------------------------------

// Minimal peer shim for turn.js: TURN control goes straight to
// the server; relayed traffic is unwrapped into the DTLS queue.
class TurnDirectPeer {
  constructor(socket) {
    this.socket = socket;
    this.turn = null;
    this._queue = [];
    this._waiters = [];
    socket.on("message", (msg, rinfo) => this._onPacket(msg, rinfo));
  }

  turnWrite(client, frame, channelData) {
    // Stream transports (TCP/TLS): write to the dedicated
    // connection, padding ChannelData to a 4-byte boundary
    // (RFC 5766 section 4), exactly like Peer.turnWrite.
    if (client.stream) {
      let out = frame;
      if (channelData) {
        const pad = (4 - (frame.length % 4)) % 4;
        if (pad > 0) out = Buffer.concat([frame, Buffer.alloc(pad)]);
      }
      client.stream.write(out);
      return;
    }
    this.socket.send(frame, client.server.port, client.server.address, () => {});
  }

  onTurnPacket(msg) {
    if (!this.turn) return;
    if (msg.length >= 4 && msg[0] >= 0x40 && msg[0] <= 0x7f) {
      const framed = unwrapChannelData(msg);
      if (framed && this.turn.channels.has(framed.channel)) this._deliver(framed.data);
      return;
    }
    const stun = StunMessage.decode(msg);
    if (!stun) return;
    if (stun.type === StunMessageType.DATA_INDICATION) {
      const unwrapped = unwrapDataIndication(stun);
      if (unwrapped) this._deliver(Buffer.from(unwrapped.data));
      return;
    }
    this.turn.resolve(stun);
  }

  _onPacket(msg, rinfo) {
    if (
      this.turn &&
      rinfo.address === this.turn.server.address &&
      rinfo.port === this.turn.server.port
    ) {
      this.onTurnPacket(msg);
      return;
    }
    this._deliver(msg);
  }

  _deliver(msg) {
    const waiter = this._waiters.shift();
    if (waiter) waiter(msg);
    else this._queue.push(msg);
  }

  // DTLS packet IO over the allocation.
  io(remote) {
    const peer = this;
    return {
      send(buf) {
        const channel = peer.turn.bindings.get(`${remote.address}:${remote.port}`);
        const frame =
          channel !== undefined
            ? wrapChannelData(channel, buf)
            : wrapSendIndication(peer.turn, buf, remote);
        peer.turnWrite(peer.turn, frame, channel !== undefined);
        return Promise.resolve();
      },
      recv(timeoutMs) {
        if (peer._queue.length) return Promise.resolve(peer._queue.shift());
        return new Promise((resolve) => {
          const waiter = (msg) => {
            clearTimeout(timer);
            resolve(msg);
          };
          const timer = setTimeout(() => {
            const i = peer._waiters.indexOf(waiter);
            if (i >= 0) peer._waiters.splice(i, 1);
            resolve(null);
          }, timeoutMs);
          peer._waiters.push(waiter);
        });
      },
    };
  }
}

// Dial a Direct listener through a TURN allocation. `turnCfg`
// is {address, username, password} as in turn.js.
export async function directDialTurn(remote, certhash, { certificate = Certificate.generate(), turn: turnCfg } = {}) {
  const digest = parseCerthash(certhash);
  if (!digest) throw new Error("bad certhash");
  if (!turnCfg) throw new Error("directDialTurn: turn config required");
  const v6 = String(remote.address).includes(":");
  const socket = await bindSocket(v6 ? "udp6" : "udp4", 0, v6 ? "::" : "0.0.0.0");
  const peer = new TurnDirectPeer(socket);
  try {
    const client = await allocateTurn(peer, turnCfg, 5000);
    if (!client.relayed) throw new Error("turn: no relayed address");
    await createPermissions(peer, client, [remote], 5000);
    await bindChannels(peer, client, [remote], 5000);
    const dtls = await DtlsConnection.connect(peer.io(remote), clientConfig(certificate, digest));
    return withTransportClose(new DcEndpoint(dtls, "client"), () => {
      client.stop();
      try {
        socket.close();
      } catch {}
    });
  } catch (err) {
    peer.turn?.stop();
    try {
      socket.close();
    } catch {}
    throw err;
  }
}

export async function directDialTurnMultiaddr(multiaddr, opts = {}) {
  const parsed = parseDirectMultiaddr(multiaddr);
  if (!parsed) throw new Error("bad direct multiaddr");
  return directDialTurn(parsed.remote, certhashOfDigest(parsed.digest), opts);
}

// Re-exported so generated code has one import surface.
export { Certificate };
export const newCertificate = (cn) => Certificate.generate(cn ?? "dc-webrtc");
