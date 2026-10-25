// Shared-socket multiplexing for signaled peers: many Peers
// over one bound UDP socket — the single-port server topology
// (Jitsi's 10000/udp, Pion's UDPMux). One dgram socket routes
// each datagram to one peer endpoint:
//   - STUN packets route by the ICE username's local ufrag
//     (registered when the peer is created).
//   - Everything else (DTLS) routes by source address, learned
//     from that peer's STUN traffic. A NAT rebinding can drop
//     a datagram until the pair's next consent check
//     re-teaches the route; DTLS/SCTP retransmission covers
//     the gap.
//   - DTLS packets route by connection id (RFC 9146): each
//     endpoint is allocated a 10-byte cid (shared port +
//     counter) at createPeer and announces it in the DTLS
//     handshake, so every record after the first ClientHello
//     routes by exact map lookup — source-independent, so
//     mux-to-mux pairs and NAT rebinding keep working. The
//     first ClientHello itself carries no cid on the wire,
//     so it routes by its DcPairHint extension (the remote
//     peer's ICE ufrag, already keyed by byUfrag); the learned
//     source remains the fallback for peers that ignore the
//     connection_id extension (e.g. browsers).
//   - TURN traffic never touches the shared socket: a muxed
//     peer's allocation rides a dedicated per-peer socket
//     (see Peer), so no TURN demux is needed here.
//   - A Binding Success carries no username, so it is
//     offered to every endpoint; each peer consumes only its
//     own (integrity-checked) transaction — the srflx waiter
//     during gathering, the ICE agent otherwise. Offering to
//     all is what makes a shared source (mux-to-mux) route
//     deterministically instead of by last-learned source.
// TURN is unavailable on muxed peers.
// Node-only (dgram); browsers manage their own sockets.

import dgram from "node:dgram";
import { EventEmitter } from "node:events";
import { Peer } from "./peer.js";
import { Reader } from "./dtls.js";
import { StunMessage } from "./stun.js";
import {
  DtlsContentType,
  DtlsExtension,
  DtlsHandshakeType,
  StunAttribute,
  StunMessageType,
} from "./proto_gen.js";

// Extract the DcPairHint extension from an epoch-0
// ClientHello record (unfragmented, as our stacks emit it).
function pairHintFromClientHello(msg) {
  try {
    const r = new Reader(msg);
    if (r.u8() !== DtlsContentType.HANDSHAKE) return null;
    r.take(2);
    r.take(2);
    r.take(6);
    r.u16();
    if (r.u8() !== DtlsHandshakeType.CLIENT_HELLO) return null;
    r.u24();
    r.take(2); // message sequence
    r.take(3); // fragment offset
    r.u24(); // fragment length
    r.take(34);
    r.vec8();
    r.vec8();
    r.vec16();
    r.vec8();
    const exts = r.vec16();
    const er = new Reader(exts);
    while (!er.done()) {
      const ty = er.u16();
      const data = er.vec16();
      if (ty === DtlsExtension.DC_PAIR_HINT) return data.toString("utf8");
    }
  } catch {
    return null;
  }
  return null;
}

// One peer's view of the shared socket, with the dgram
// surface Peer uses: on("message"), send, address, close.
class MuxEndpoint extends EventEmitter {
  constructor(mux) {
    super();
    this.mux = mux;
    this.ufrag = null;
    this.cid = null;
  }

  // This endpoint's allocated DTLS connection id (RFC 9146).
  localCid() {
    return this.cid;
  }

  send(buf, port, address, callback) {
    this.mux.socket.send(buf, port, address, callback ?? (() => {}));
  }

  address() {
    return this.mux.socket.address();
  }

  close() {
    this.mux.unregister(this);
  }

  deliver(msg, rinfo) {
    this.emit("message", msg, rinfo);
  }
}

export class PeerMux {
  #socket;
  #byUfrag = new Map();
  #bySrc = new Map();
  #byCid = new Map();
  #cidSeq = 0n;
  #endpoints = new Set();

  constructor(socket) {
    this.#socket = socket;
    socket.on("error", () => {}); // async errors must not crash the process
    socket.on("message", (msg, rinfo) => this.#route(msg, rinfo));
  }

  // Bind the shared socket (udp4 unless family says udp6).
  static async bind({ address = "0.0.0.0", port = 0, family = "udp4" } = {}) {
    const socket = dgram.createSocket(family);
    await new Promise((resolve, reject) => {
      socket.once("error", reject);
      socket.bind(port, address, resolve);
    });
    // Large SCTP bursts overflow default kernel buffers;
    // drops then cost an RTO round. Best-effort hint.
    try {
      socket.setRecvBufferSize(4 * 1024 * 1024);
      socket.setSendBufferSize(4 * 1024 * 1024);
    } catch {
      /* buffer sizes are a hint, not a requirement */
    }
    return new PeerMux(socket);
  }

  // The bound address every created peer advertises (by port).
  address() {
    return this.#socket.address();
  }

  get socket() {
    return this.#socket;
  }

  // A peer on the shared socket. Options mirror Peer.create
  // minus binding. TURN is supported: the allocation's UDP
  // leg rides a dedicated per-peer socket (an allocation
  // pins a concrete 5-tuple); TCP/TLS TURN rides its stream.
  async createPeer(options = {}) {
    const endpoint = new MuxEndpoint(this);
    const peer = await Peer.createWithSocket(endpoint, options);
    endpoint.ufrag = peer.localUfrag;
    this.#byUfrag.set(endpoint.ufrag, endpoint);
    // Allocate this endpoint's DTLS connection id (RFC 9146):
    // the shared port's bytes plus a counter — unique per
    // endpoint, fixed length so routing is an exact lookup.
    this.#cidSeq += 1n;
    const cid = Buffer.alloc(10);
    cid.writeUInt16BE(this.#socket.address().port & 0xffff, 0);
    cid.writeBigUInt64BE(this.#cidSeq, 2);
    endpoint.cid = cid;
    this.#byCid.set(cid.toString("hex"), endpoint);
    this.#endpoints.add(endpoint);
    // Peer.close() closes its socket; on an endpoint that is
    // just unregister() above.
    return peer;
  }

  unregister(endpoint) {
    if (endpoint.cid && this.#byCid.get(endpoint.cid.toString("hex")) === endpoint) {
      this.#byCid.delete(endpoint.cid.toString("hex"));
    }
    if (endpoint.ufrag && this.#byUfrag.get(endpoint.ufrag) === endpoint) {
      this.#byUfrag.delete(endpoint.ufrag);
    }
    for (const [src, ep] of this.#bySrc) {
      if (ep === endpoint) this.#bySrc.delete(src);
    }
    this.#endpoints.delete(endpoint);
  }

  close() {
    this.#socket.close();
  }

  #route(msg, rinfo) {
    const srcKey = `${rinfo.address}:${rinfo.port}`;
    if (msg.length > 0 && msg[0] < 4) {
      const stun = StunMessage.decode(msg);
      if (stun) {
        const username = stun.attr(StunAttribute.USERNAME);
        if (username) {
          const local = username.toString("utf8").split(":")[0];
          const endpoint = this.#byUfrag.get(local);
          if (endpoint) {
            this.#bySrc.set(srcKey, endpoint);
            endpoint.deliver(msg, rinfo);
            return;
          }
        }
        // A Binding Success carries no username. Offer it to
        // every endpoint: each agent consumes only its own
        // transaction (integrity-checked), and a shared source
        // (mux-to-mux) makes the learned source ambiguous.
        if (stun.type === StunMessageType.BINDING_SUCCESS) {
          for (const endpoint of this.#endpoints) endpoint.deliver(msg, rinfo);
          return;
        }
        const known = this.#bySrc.get(srcKey);
        if (known) {
          known.deliver(msg, rinfo);
          return;
        }
        return;
      }
      return;
    }
    // DTLS: an epoch-0 ClientHello routes by its DcPairHint;
    // everything else routes by connection id (source-
    // independent, so mux-to-mux and NAT rebinding keep
    // working); the learned source is the fallback.
    const byHint = this.#endpointByHint(msg);
    if (byHint) {
      byHint.deliver(msg, rinfo);
      return;
    }
    const byCid = this.#endpointByCid(msg);
    if (byCid) {
      byCid.deliver(msg, rinfo);
      return;
    }
    const endpoint = this.#bySrc.get(srcKey);
    if (endpoint) endpoint.deliver(msg, rinfo);
  }

  // Route a first-flight ClientHello by its DcPairHint
  // extension (the remote peer's ICE ufrag, which the
  // byUfrag table already keys).
  #endpointByHint(msg) {
    const hint = pairHintFromClientHello(msg);
    return hint ? (this.#byUfrag.get(hint) ?? null) : null;
  }

  // Route a DTLS record by the connection id after its
  // header (offset 11: type, version, epoch, seq).
  #endpointByCid(msg) {
    if (msg.length < 21) return null;
    return this.#byCid.get(msg.subarray(11, 21).toString("hex")) ?? null;
  }
}
