// Rendezvous listener: a fixed, pre-published WebRTC endpoint
// browsers can connect to with no signaling exchange at all.
//
// The listener owns one UDP socket, one fixed ICE ufrag/pwd
// pair, and one fixed DTLS certificate. Those four values plus
// the public host/port form a rendezvous descriptor, published
// beforehand (hardcoded, DNS, an HTTPS file — host's choice).
// A browser synthesizes this endpoint's SDP locally from the
// descriptor (see the generated rendezvousChannel), answers it
// in-page, and starts ICE as the controlling agent (the
// descriptor says ICE-lite). Nothing is ever transmitted
// out of band after publication.
//
// Server side of each dial: the first STUN Binding request
// carries the dialer's ufrag in its USERNAME. The listener
// spawns a Peer for it with the fixed credentials/certificate,
// synthesizes the dialer's offer from the packet's source
// address (its ICE pwd and DTLS fingerprint are unknown; the
// peer requires neither), and feeds the packet in. The dialer
// nominates (USE-CANDIDATE), DTLS runs with this side as
// server presenting the fixed cert, and the "grpc" channel is
// delivered to onChannel like any other peer's.

import crypto from "node:crypto";
import dgram from "node:dgram";
import net from "node:net";
import { EventEmitter } from "node:events";

import { Peer } from "./peer.js";
import { StunMessage } from "./stun.js";
import { StunAttribute } from "./proto_gen.js";
import { Certificate } from "./x509.js";

function randomToken(chars, length) {
  const bytes = crypto.randomBytes(length);
  let out = "";
  for (const byte of bytes) out += chars[byte % chars.length];
  return out;
}

function synthesizedOffer(rinfo, remoteUfrag) {
  const family = net.isIPv6(rinfo.address) ? "IP6" : "IP4";
  return [
    "v=0",
    "o=- 0 0 IN IP4 0.0.0.0",
    "s=-",
    "t=0 0",
    "a=group:BUNDLE 0",
    "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
    `c=IN ${family} ${rinfo.address}`,
    `a=candidate:1 1 udp 2130706431 ${rinfo.address} ${rinfo.port} typ host generation 0`,
    "a=end-of-candidates",
    `a=ice-ufrag:${remoteUfrag}`,
    "a=ice-pwd:rendezvousUnknownPwd0000",
    "a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
    "a=setup:actpass",
    "a=mid:0",
    "a=sctp-port:5000",
    "a=max-message-size:262144",
    "",
  ].join("\r\n");
}

class RendezvousEndpoint extends EventEmitter {
  constructor(listener, session) {
    super();
    this.listener = listener;
    this.session = session;
  }

  send(buf, port, address, callback) {
    // Route via the shared socket to the session's current
    // source (the peer's remote is that source; honoring the
    // requested destination directly is equivalent on this
    // listener and keeps NAT-source updates in one place).
    this.listener.socket.send(buf, port, address, callback ?? (() => {}));
  }

  address() {
    return this.listener.socket.address();
  }

  close() {
    this.listener.dropSession(this.session);
  }

  deliver(msg, rinfo) {
    this.emit("message", msg, rinfo);
  }
}

export class RendezvousListener {
  #socket;
  #sessionsByRemote = new Map();
  #sessionsBySrc = new Map();
  #onChannel;
  #onError;
  #localIps;
  #iceUfrag;
  #icePwd;
  #certificate;
  #consentIntervalMs;
  #consentExpiryMs;
  #mux = null;

  constructor(socket, options = {}) {
    this.#socket = socket;
    this.#onChannel = options.onChannel ?? (() => {});
    this.#onError = options.onError ?? ((e) => console.error("rendezvous:", e));
    this.#localIps = options.localIps ?? null;
    this.#consentIntervalMs = options.consentIntervalMs;
    this.#consentExpiryMs = options.consentExpiryMs;
    this.#iceUfrag = options.iceUfrag ?? randomToken("abcdefghijklmnopqrstuvwxyz0123456789", 8);
    this.#icePwd = options.icePwd ?? randomToken("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", 24);
    this.#certificate = options.certificate ?? Certificate.generate();
    if (options.mux) {
      // Shared-socket mode: the PeerMux owns the socket and
      // its reader; packets it cannot attribute to a
      // registered peer come to us, and session peers send
      // via the mux socket. One UDP port then serves both
      // HTTP-signaled peers (mux) and rendezvous browsers.
      this.#mux = options.mux;
      this.#mux.setUnhandledHandler((msg, rinfo) => void this.#route(msg, rinfo));
    } else {
      socket.on("error", () => {});
      socket.on("message", (msg, rinfo) => void this.#route(msg, rinfo));
    }
  }

  /** The shared UDP socket all sessions use. */
  get socket() {
    return this.#socket;
  }

  static async bind({ address = "0.0.0.0", port = 0, family = "udp4", ...options } = {}) {
    if (options.mux) {
      return new RendezvousListener(options.mux.socket, options);
    }
    const socket = dgram.createSocket(family);
    socket.on("error", () => {});
    await new Promise((resolve, reject) => {
      socket.once("error", reject);
      socket.bind(port, address, resolve);
    });
    try {
      socket.setRecvBufferSize(4 * 1024 * 1024);
      socket.setSendBufferSize(4 * 1024 * 1024);
    } catch {
      /* buffer-size hints only */
    }
    return new RendezvousListener(socket, options);
  }

  /**
   * The publishable descriptor for `host` (the public IP or
   * name browsers should dial). Same shape the generated
   * browser rendezvousChannel consumes.
   */
  descriptor(host) {
    const { port } = this.#socket.address();
    return {
      host,
      port,
      iceUfrag: this.#iceUfrag,
      icePwd: this.#icePwd,
      fingerprint: this.#certificate.fingerprint(),
      setup: "passive",
    };
  }

  dropSession(session) {
    if (!session) return;
    if (this.#sessionsByRemote.get(session.remoteUfrag) === session) {
      this.#sessionsByRemote.delete(session.remoteUfrag);
    }
    for (const [src, candidate] of this.#sessionsBySrc) {
      if (candidate === session) this.#sessionsBySrc.delete(src);
    }
  }

  async #spawnSession(rinfo, remoteUfrag, firstPacket) {
    const session = { remoteUfrag, peer: null, endpoint: null };
    const endpoint = new RendezvousEndpoint(this, session);
    session.endpoint = endpoint;
    const peer = await Peer.createWithSocket(endpoint, {
      localIps: this.#localIps,
      requirePeerCertificate: false,
      iceUfrag: this.#iceUfrag,
      icePwd: this.#icePwd,
      certificate: this.#certificate,
      consentIntervalMs: this.#consentIntervalMs,
      consentExpiryMs: this.#consentExpiryMs,
    });
    session.peer = peer;
    this.#sessionsByRemote.set(remoteUfrag, session);
    this.#sessionsBySrc.set(`${rinfo.address}:${rinfo.port}`, session);
    peer.handleRendezvousOffer(synthesizedOffer(rinfo, remoteUfrag));
    endpoint.deliver(firstPacket, rinfo);
    void (async () => {
      try {
        const dcEndpoint = await peer.connect();
        dcEndpoint.onchannel = (channel) => this.#onChannel(channel, peer);
      } catch (e) {
        this.dropSession(session);
        this.#onError(e);
      }
    })();
    return session;
  }

  async #route(msg, rinfo) {
    const srcKey = `${rinfo.address}:${rinfo.port}`;
    if (msg.length > 0 && msg[0] < 4) {
      const stun = StunMessage.decode(msg);
      const username = stun?.attr(StunAttribute.USERNAME)?.toString("utf8");
      if (username) {
        const [local, remote] = username.split(":");
        if (local !== this.#iceUfrag || !remote) return;
        let session = this.#sessionsByRemote.get(remote);
        if (!session) {
          session = await this.#spawnSession(rinfo, remote, msg);
          return;
        }
        this.#sessionsBySrc.set(srcKey, session);
        session.peer && this.#deliver(session, msg, rinfo);
        return;
      }
      const known = this.#sessionsBySrc.get(srcKey);
      if (known) this.#deliver(known, msg, rinfo);
      return;
    }
    const session = this.#sessionsBySrc.get(srcKey);
    if (session) this.#deliver(session, msg, rinfo);
  }

  #deliver(session, msg, rinfo) {
    // The endpoint is the EventEmitter handed to the Peer; it
    // hangs off the peer's socket seam (session's endpoint is
    // reachable through the peer's first packet path) — store
    // it on the session at spawn for direct delivery.
    session.endpoint?.deliver(msg, rinfo);
  }

  close() {
    for (const session of this.#sessionsByRemote.values()) {
      session.peer?.close().catch(() => {});
    }
    this.#sessionsByRemote.clear();
    this.#sessionsBySrc.clear();
    if (this.#mux) {
      // The mux owns the shared socket; just detach.
      this.#mux.setUnhandledHandler(null);
      this.#mux = null;
      return;
    }
    try {
      this.#socket.close();
    } catch {
      /* already closed */
    }
  }
}
