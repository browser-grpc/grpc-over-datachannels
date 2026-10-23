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
//   - A Binding Success with an unknown ufrag (an srflx
//     gathering response) is offered to every endpoint; each
//     peer's srflx waiter consumes only its own transaction.
//
// Like every single-port mux, this assumes each remote
// connection presents a distinct source address — the normal
// Internet case. Two muxes peering with each other would
// present one shared source for several pairs, which DTLS
// cannot demux without connection IDs (RFC 9146, not
// implemented); run at most one mux per server<->client
// relationship. TURN is unavailable on muxed peers.
// Node-only (dgram); browsers manage their own sockets.

import dgram from "node:dgram";
import { EventEmitter } from "node:events";
import { Peer } from "./peer.js";
import { StunMessage } from "./stun.js";
import { StunAttribute, StunMessageType } from "./proto_gen.js";

// One peer's view of the shared socket, with the dgram
// surface Peer uses: on("message"), send, address, close.
class MuxEndpoint extends EventEmitter {
  constructor(mux) {
    super();
    this.mux = mux;
    this.ufrag = null;
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
  // minus binding; turnServers are rejected (TURN needs a
  // concrete socket).
  async createPeer(options = {}) {
    if (options.turnServers?.length) {
      throw new Error("TURN is not available on a muxed peer");
    }
    const endpoint = new MuxEndpoint(this);
    const peer = await Peer.createWithSocket(endpoint, options);
    endpoint.ufrag = peer.localUfrag;
    this.#byUfrag.set(endpoint.ufrag, endpoint);
    this.#endpoints.add(endpoint);
    // Peer.close() closes its socket; on an endpoint that is
    // just unregister() above.
    return peer;
  }

  unregister(endpoint) {
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
        const known = this.#bySrc.get(srcKey);
        if (known) {
          known.deliver(msg, rinfo);
          return;
        }
        if (stun.type === StunMessageType.BINDING_SUCCESS) {
          for (const endpoint of this.#endpoints) endpoint.deliver(msg, rinfo);
        }
        return;
      }
      return;
    }
    const endpoint = this.#bySrc.get(srcKey);
    if (endpoint) endpoint.deliver(msg, rinfo);
  }
}
