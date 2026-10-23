// Full WebRTC peer: UDP socket + ICE (host candidates) + DTLS + SCTP.
// Mirrors webrtc/rust/src/peer.rs. Lifecycle: createOffer /
// handleOffer (returns answer) / handleAnswer, then connect() runs ICE
// checks, performs DTLS over the nominated pair, and returns a
// DcEndpoint whose channels look like RTCDataChannels.

import dgram from "node:dgram";
import net from "node:net";
import os from "node:os";
import { DtlsConnection } from "./dtls.js";
import { emitStackEvent } from "./trace.js";
import { resolveMdns } from "./mdns.js";
import { DcEndpoint } from "./endpoint.js";
import { Candidate, IceAgent } from "./ice.js";
import { StunAttribute, StunMessageType } from "./proto_gen.js";
import { StunMessage, decodeMappedAddress, isIpv6, normalizeIp, parseHostPort, parseIp } from "./stun.js";
import { generate, parse } from "./sdp.js";
import {
  addTurnPeer,
  allocateTurn,
  bindChannels,
  createPermissions,
  unwrapChannelData,
  unwrapDataIndication,
  wrapChannelData,
  wrapSendIndication,
} from "./turn.js";
import { Certificate } from "./x509.js";

function defaultLocalIps() {
  const ips = ["127.0.0.1"];
  for (const infos of Object.values(os.networkInterfaces())) {
    for (const info of infos ?? []) {
      if (info.family === "IPv4" && !info.internal && !ips.includes(info.address)) {
        ips.push(info.address);
      }
    }
  }
  return ips;
}

export class Peer {
  #socket;
  #agent;
  #certificate;
  #remote = null;
  #dtlsRole = "server";
  #requirePeerCertificate;
  #dtlsQueue = [];
  #dtlsWaiters = [];
  #srflxWaiters = new Map(); // tid hex -> resolve
  #endpoint = null;
  // Live TURN allocation (turn.js) once allocateTurn succeeds;
  // #relayActive flips at connect: pair traffic is then wrapped
  // in Send/Data indications through the allocation.
  turn = null;
  #relayActive = false;
  // Trickle callback for local candidates (setOnLocalCandidate).
  onLocalCandidate = null;
  // Invoked exactly once if consent for the nominated pair
  // expires (RFC 7675); the endpoint is then closed.
  onConsentFailure = null;
  // Invoked once per completed ICE restart (a pair from the
  // new generation nominated).
  onRenominated = null;
  #restartGen = 0;
  #closed = false;
  #lastResolveAttempt = 0;
  #consentTimer = null;
  #consentIntervalMs = 5000;
  #consentExpiryMs = 30000;

  constructor(socket, agent, certificate, { requirePeerCertificate = true } = {}) {
    this.#socket = socket;
    this.#agent = agent;
    this.#certificate = certificate;
    this.#requirePeerCertificate = requirePeerCertificate;
    socket.on("message", (msg, rinfo) => this.#onPacket(msg, rinfo));
  }

  // consentIntervalMs: how often a consent check is sent on the
  // nominated pair (default 5000; null disables). consentExpiryMs:
  // silence tolerated before consent expires (default 30000).
  static async create({
    localIps = null,
    requirePeerCertificate = true,
    stunServers = [],
    turnServers = [],
    consentIntervalMs = 5000,
    consentExpiryMs = 30000,
  } = {}) {
    const effectiveIps = localIps ?? defaultLocalIps();
    // A dual-stack udp6 socket serves IPv6 candidates (and IPv4
    // via mapped addresses, normalized in #onPacket); plain
    // udp4 keeps the historical behavior otherwise.
    const serverAddrs = [
      ...stunServers,
      ...turnServers.map((c) => c.address),
    ]
      .map((a) => parseHostPort(a, 3478)?.address)
      .filter(Boolean);
    const wantsV6 =
      effectiveIps.some((ip) => isIpv6(ip)) || serverAddrs.some((ip) => isIpv6(ip));
    const socket = dgram.createSocket(wantsV6 ? "udp6" : "udp4");
    socket.on("error", () => {}); // async send errors must not crash the process
    await new Promise((resolve) => socket.bind(0, wantsV6 ? "::" : "0.0.0.0", resolve));
    return Peer.createWithSocket(socket, {
      localIps,
      requirePeerCertificate,
      stunServers,
      turnServers,
      consentIntervalMs,
      consentExpiryMs,
    });
  }

  // Build a peer on an already-bound datagram socket (a real
  // dgram socket from create(), or a PeerMux endpoint — the
  // single-socket seam in mux.js). Candidates advertise the
  // socket's port. TURN requires a real socket.
  static async createWithSocket(
    socket,
    {
      localIps = null,
      requirePeerCertificate = true,
      stunServers = [],
      turnServers = [],
      consentIntervalMs = 5000,
      consentExpiryMs = 30000,
    } = {},
  ) {
    const effectiveIps = localIps ?? defaultLocalIps();
    const { port } = socket.address();
    const agent = new IceAgent(true);
    agent.localCandidates = effectiveIps.map((ip, i) =>
      Candidate.host(ip, port, String(i + 1)),
    );
    const peer = new Peer(socket, agent, Certificate.generate(), { requirePeerCertificate });
    peer.#consentIntervalMs = consentIntervalMs;
    peer.#consentExpiryMs = consentExpiryMs;
    for (const server of stunServers) {
      await peer.gatherSrflx(server); // failures ignored: host candidates still apply
    }
    if (turnServers.length > 0 && !(socket instanceof dgram.Socket)) {
      throw new Error("TURN is not available on a muxed peer");
    }
    for (const cfg of turnServers) {
      try {
        const client = await allocateTurn(peer, cfg);
        const base = agent.localCandidates[0];
        if (!agent.localCandidates.some((c) => c.address === client.relayed.address && c.port === client.relayed.port)) {
          const cand = Candidate.relay(client.relayed.address, client.relayed.port, base, String(agent.localCandidates.length + 1));
          agent.localCandidates.push(cand);
          peer.#emitLocalCandidate(cand);
        }
        break; // one relay candidate is enough
      } catch {
        peer.turn?.stop();
        peer.turn = null; // unreachable TURN server: host/srflx still apply
      }
    }
    return peer;
  }

  // Raw socket send. On a dual-stack udp6 socket, libuv
  // rejects plain IPv4 destinations (EINVAL); the mapped form
  // ::ffff:a.b.c.d is required.
  #sendRaw(buf, port, address) {
    let dest = address;
    if (net.isIPv4(address)) {
      try {
        if (this.#socket.address().family === "IPv6") dest = `::ffff:${address}`;
      } catch {
        // socket not bound yet: send will fail harmlessly
      }
    }
    this.#socket.send(buf, port, dest, () => {});
  }

  // Direct socket send for TURN control traffic (never wrapped).
  sendTurnControl(buf, port, address) {
    this.#sendRaw(buf, port, address);
  }

  // Send one TURN message to the server: over the dedicated
  // stream connection for TCP/TLS allocations (ChannelData
  // frames padded to a 4-byte boundary, RFC 5766 section 4),
  // else as a UDP datagram on the peer socket.
  turnWrite(client, frame, channelData) {
    if (client.stream) {
      let out = frame;
      if (channelData) {
        const pad = (4 - (frame.length % 4)) % 4;
        if (pad > 0) out = Buffer.concat([frame, Buffer.alloc(pad)]);
      }
      client.stream.write(out);
      return;
    }
    this.#sendRaw(frame, client.server.port, client.server.address);
  }

  // Handle one message from the TURN server (a UDP datagram, or
  // one framed message off the TCP/TLS stream): relayed traffic
  // is unwrapped and re-injected as if it arrived from the
  // peer; control responses resolve request waiters.
  onTurnPacket(msg) {
    if (!this.turn) return;
    if (msg.length >= 4 && msg[0] >= 0x40 && msg[0] <= 0x7f) {
      const framed = unwrapChannelData(msg);
      const peerAddr = framed && this.turn.channels.get(framed.channel);
      if (peerAddr) this.#onPacket(framed.data, peerAddr);
      return;
    }
    const stun = StunMessage.decode(msg);
    if (stun) {
      if (stun.type === StunMessageType.DATA_INDICATION) {
        const unwrapped = unwrapDataIndication(stun);
        if (unwrapped) this.#onPacket(unwrapped.data, unwrapped.peer);
        return;
      }
      this.turn.resolve(stun);
    }
  }

  // Send pair traffic (ICE checks/responses, DTLS) through the
  // allocation once the relay is active: ChannelData framing
  // when a channel is bound for the peer, Send indication else.
  #sendTo(buf, remote) {
    // Relay wrapping names the peer by IP (XOR-PEER-ADDRESS);
    // mDNS ".local" remotes go direct instead.
    if (this.turn && this.#relayActive && parseIp(remote.address)) {
      const channel = this.turn.bindings.get(`${remote.address}:${remote.port}`);
      const wrapped =
        channel !== undefined ? wrapChannelData(channel, buf) : wrapSendIndication(this.turn, buf, remote);
      this.turnWrite(this.turn, wrapped, channel !== undefined);
      return;
    }
    this.#sendRaw(buf, remote.port, remote.address);
  }

  // Query one STUN server ("host:port") for a server-reflexive
  // candidate (RFC 8445 section 5.1.2). The request rides the peer's
  // own socket so the mapping is the one ICE checks will use; the
  // read loop demultiplexes the response by transaction id.
  // Resolves true when a candidate was added.
  async gatherSrflx(server, timeoutMs = 1200) {
    const parsed = parseHostPort(server, 3478);
    if (!parsed) return false;
    const { address: host, port } = parsed;
    const request = new StunMessage(StunMessageType.BINDING_REQUEST);
    const tid = request.transactionId.toString("hex");
    const responsePromise = new Promise((resolve) => {
      this.#srflxWaiters.set(tid, resolve);
    });
    this.#sendRaw(request.encode(null), port, host);
    const mapped = await Promise.race([
      responsePromise,
      new Promise((resolve) => setTimeout(() => resolve(null), timeoutMs)),
    ]);
    this.#srflxWaiters.delete(tid);
    if (!mapped) return false;
    if (this.#agent.localCandidates.some((c) => c.address === mapped.address && c.port === mapped.port)) {
      return false; // already have this address (e.g. host on a flat network)
    }
    const base = this.#agent.localCandidates[0];
    const cand = Candidate.srflx(mapped.address, mapped.port, base, String(this.#agent.localCandidates.length + 1));
    this.#agent.localCandidates.push(cand);
    this.#emitLocalCandidate(cand);
    return true;
  }

  #emitLocalCandidate(cand) {
    if (this.onLocalCandidate) this.onLocalCandidate(cand.toSdp());
  }

  // Register the trickle callback for local candidates and
  // immediately replay the candidates gathered so far; candidates
  // gathered later (explicit gatherSrflx calls) fire as added.
  // Candidates gathered inside Peer.create are covered by the
  // replay, since registration necessarily follows creation.
  setOnLocalCandidate(cb) {
    this.onLocalCandidate = cb;
    if (cb) for (const cand of this.#agent.localCandidates) cb(cand.toSdp());
  }

  // Local candidates as SDP lines ("a=candidate:...") for
  // trickle signaling.
  localCandidateLines() {
    return this.#agent.localCandidates.map((c) => c.toSdp());
  }

  // Trickle one remote candidate in after the remote description
  // was applied (RFC 8445 trickle ICE). Accepts a full SDP line
  // ("a=candidate:..."), the bare candidate value ("candidate:...",
  // as browsers hand to addIceCandidate), an end-of-candidates
  // line, or an empty string; the latter two are accepted no-ops.
  // Returns true when a new candidate was added (duplicates and
  // malformed lines return false). Safe to call while connect()
  // is running; mDNS ".local" addresses resolve asynchronously,
  // as connect() does for SDP-carried candidates.
  addRemoteCandidate(line) {
    const text = String(line ?? "").trim();
    if (!text || text.includes("end-of-candidates")) return false;
    const cand = Candidate.fromSdp(text.replace(/^a=/, ""));
    if (!cand) return false;
    if (!this.#agent.addRemoteCandidate(cand)) return false;
    if (!net.isIP(cand.address)) {
      resolveMdns(cand.address)
        .then((ip) => {
          if (ip) {
            cand.address = ip;
            this.#turnAddCandidate(cand);
          }
        })
        .catch(() => {});
    } else {
      this.#turnAddCandidate(cand);
    }
    return true;
  }

  // Candidates trickled in after the connect-time snapshot also
  // need TURN permissions (and a channel binding), or the relay
  // silently drops their traffic. Valid any time an allocation
  // exists; fire-and-forget like the connect-time calls.
  #turnAddCandidate(cand) {
    if (!this.turn) return;
    addTurnPeer(this, this.turn, { address: cand.address, port: cand.port }).catch(() => {});
  }

  // This peer's local ICE ufrag (mux registration).
  get localUfrag() {
    return this.#agent.localUfrag;
  }

  #localDescription(setup) {
    return {
      ufrag: this.#agent.localUfrag,
      pwd: this.#agent.localPwd,
      fingerprint: this.#certificate.fingerprint(),
      setup,
      candidates: this.#agent.localCandidates,
      sctpPort: 5000,
    };
  }

  #onPacket(msg, rinfo) {
    if (msg.length === 0) return;
    // Dual-stack sockets report IPv4 senders as ::ffff:a.b.c.d.
    if (rinfo && typeof rinfo.address === "string") {
      rinfo = { ...rinfo, address: normalizeIp(rinfo.address) };
    }
    // TURN demux: packets from the TURN server are allocation
    // control responses or relayed traffic (ChannelData frames
    // or Data indications), never agent STUN or DTLS directly.
    if (
      this.turn &&
      rinfo.address === this.turn.server.address &&
      rinfo.port === this.turn.server.port
    ) {
      this.onTurnPacket(msg);
      return;
    }
    const src = { address: rinfo.address, port: rinfo.port };
    if (msg[0] < 4) {
      // A Binding Success answering a srflx gathering request is
      // consumed here, not by the ICE agent.
      const stun = StunMessage.decode(msg);
      if (stun && stun.type === StunMessageType.BINDING_SUCCESS) {
        const resolve = this.#srflxWaiters.get(stun.transactionId.toString("hex"));
        if (resolve) {
          resolve(decodeMappedAddress(stun, true) ?? decodeMappedAddress(stun, false));
          return;
        }
      }
      const { responses } = this.#agent.handleStun(msg, src);
      for (const { bytes, remote } of responses) {
        this.#sendTo(bytes, remote);
      }
    } else if (msg[0] >= 20 && msg[0] < 64) {
      const waiter = this.#dtlsWaiters.shift();
      if (waiter) waiter(msg);
      else this.#dtlsQueue.push(msg);
    }
  }

  createOffer() {
    this.#agent.controlling = true;
    this.#dtlsRole = "server"; // actpass: the answer decides
    return generate(this.#localDescription("actpass"), true);
  }

  handleOffer(offerSdp) {
    const remote = parse(offerSdp);
    this.#applyRemote(remote);
    this.#agent.controlling = false;
    this.#dtlsRole = "client"; // answer as setup=active
    return generate(this.#localDescription("active"), false);
  }

  handleAnswer(answerSdp) {
    const remote = parse(answerSdp);
    this.#dtlsRole = remote.setup === "active" ? "server" : "client";
    this.#applyRemote(remote);
  }

  #applyRemote(remote) {
    this.#agent.setRemote(remote.ufrag, remote.pwd, remote.candidates);
    this.#remote = remote;
  }

  // Browsers advertise mDNS ".local" host candidates; resolve
  // them to IPs so connectivity checks can be addressed directly.
  async #resolveRemoteCandidates() {
    await Promise.all(
      this.#agent.remoteCandidates
        .filter((c) => !net.isIP(c.address))
        .map(async (c) => {
          const ip = await resolveMdns(c.address).catch(() => null);
          if (ip) c.address = ip;
        }),
    );
  }

  // Retry mDNS resolution at most once a second while checks
  // are in flight: a browser's mDNS responder can miss the
  // initial window under load, and an unresolved ".local"
  // candidate would otherwise silently never be checked.
  #maybeResolveRemote() {
    const now = Date.now();
    if (now - this.#lastResolveAttempt < 1000) return;
    if (!this.#agent.remoteCandidates.some((c) => !net.isIP(c.address))) return;
    this.#lastResolveAttempt = now;
    void this.#resolveRemoteCandidates();
  }

  // The SDP setup value that keeps the existing DTLS
  // association across an ICE restart.
  #restartSetup() {
    return this.#dtlsRole === "client" ? "active" : "passive";
  }

  // Begin an ICE restart on a connected peer (RFC 8445
  // section 5.1): fresh local credentials, same candidates and
  // DTLS fingerprint. Hand the result to the remote's
  // handleRestartOffer and apply its answer with
  // handleRestartAnswer; media keeps flowing on the old pair
  // until renomination, which fires onRenominated.
  createRestartOffer() {
    this.#agent.restart();
    return generate(this.#localDescription(this.#restartSetup()), true);
  }

  // Apply a restart offer (fresh local credentials too) and
  // return the restart answer SDP.
  handleRestartOffer(offerSdp) {
    const remote = parse(offerSdp);
    this.#agent.restart();
    this.#applyRemote(remote);
    this.#startRestartChecks();
    return generate(this.#localDescription(this.#restartSetup()), false);
  }

  // Apply a restart answer SDP.
  handleRestartAnswer(answerSdp) {
    this.#applyRemote(parse(answerSdp));
    this.#startRestartChecks();
  }

  // Drive connectivity checks for the current ICE generation
  // until renomination (mirrors the connect loop; TURN
  // permissions are refreshed first). At most one loop runs
  // per generation.
  async #startRestartChecks() {
    const generation = this.#agent.generation;
    if (this.#restartGen === generation) return;
    this.#restartGen = generation;
    await this.#resolveRemoteCandidates();
    if (this.turn) {
      await createPermissions(this, this.turn, this.#agent.remoteCandidates).catch(() => {});
      if (this.turn.peers.length) {
        await bindChannels(this, this.turn, this.turn.peers).catch(() => {});
      }
    }
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      this.#maybeResolveRemote();
      if (this.#closed || this.#restartGen !== generation) return;
      if (this.#agent.renominated && this.#agent.generation === generation) {
        this.onRenominated?.();
        return;
      }
      for (const { bytes, remote } of this.#agent.dueChecks()) {
        this.#sendTo(bytes, remote);
      }
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  async connect() {
    if (!this.#remote) throw new Error("no remote description");
    await this.#resolveRemoteCandidates();
    if (this.turn) {
      // Relay the session: permissions (and channels) for every
      // remote candidate first, then all pair traffic goes
      // through the allocation (wrapped by #sendTo).
      await createPermissions(this, this.turn, this.#agent.remoteCandidates);
      if (this.turn.peers.length) await bindChannels(this, this.turn, this.turn.peers);
      this.#relayActive = true;
    }
    const deadline = Date.now() + 15000;
    while (!this.#agent.nominated) {
      if (Date.now() > deadline) throw new Error("ICE nomination timed out");
      this.#maybeResolveRemote();
      for (const { bytes, remote } of this.#agent.dueChecks()) {
        this.#sendTo(bytes, remote);
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    const selected = this.#agent.nominated;
    emitStackEvent("ice.nominated", String(selected));
    const connectGen = this.#agent.generation;
    let ioDest = selected;
    const self = this;
    const io = {
      send: (buf) =>
        new Promise((resolve) => {
          // Media destination is pinned to the pair nominated
          // at connect (later same-generation nominations,
          // e.g. a browser re-nominating another pair, must
          // not drift it); an ICE restart's renomination is
          // the one switch point.
          if (self.#agent.renominated && self.#agent.generation !== connectGen) {
            ioDest = self.#agent.nominated;
          }
          self.#sendTo(buf, ioDest);
          resolve();
        }),
      recv: (timeoutMs) => {
        if (this.#dtlsQueue.length) return Promise.resolve(this.#dtlsQueue.shift());
        return new Promise((resolve) => {
          const waiter = (msg) => {
            clearTimeout(timer);
            resolve(msg);
          };
          const timer = setTimeout(() => {
            const i = this.#dtlsWaiters.indexOf(waiter);
            if (i >= 0) this.#dtlsWaiters.splice(i, 1);
            resolve(null);
          }, timeoutMs);
          this.#dtlsWaiters.push(waiter);
        });
      },
    };
    const config = {
      certificate: this.#certificate,
      expectedPeerFingerprint: this.#remote.fingerprint,
      requirePeerCertificate: this.#requirePeerCertificate,
    };
    const dtls =
      this.#dtlsRole === "client"
        ? await DtlsConnection.connect(io, config)
        : await DtlsConnection.accept(io, config);
    emitStackEvent("dtls.handshake", dtls.wasResumed?.() ? "resumed" : "full");
    this.#endpoint = new DcEndpoint(dtls, this.#dtlsRole);
    emitStackEvent("endpoint.ready", this.#dtlsRole);
    this.#startConsentLoop();
    return this.#endpoint;
  }

  // Periodically re-check the nominated pair (RFC 7675 consent
  // freshness). On expiry, closes the endpoint and fires
  // onConsentFailure once.
  #startConsentLoop() {
    if (!this.#consentIntervalMs) return;
    // The DTLS handshake just proved the pair; start the
    // consent clock from here, not from nomination.
    this.#agent.touchConsent();
    const tick = () => {
      const check = this.#agent.consentCheck();
      if (check) this.#sendTo(check.bytes, check.remote);
      if (this.#agent.consentExpired(this.#consentExpiryMs)) {
        this.#stopConsentLoop();
        try {
          this.onConsentFailure?.();
        } catch {
          /* handler errors must not crash the loop owner */
        }
        this.#endpoint?.close().catch(() => {});
        return;
      }
      this.#consentTimer = setTimeout(tick, this.#consentIntervalMs);
      this.#consentTimer.unref?.();
    };
    this.#consentTimer = setTimeout(tick, this.#consentIntervalMs);
    this.#consentTimer.unref?.();
  }

  #stopConsentLoop() {
    if (this.#consentTimer) clearTimeout(this.#consentTimer);
    this.#consentTimer = null;
  }

  // Whether consent freshness has lapsed for the nominated pair.
  consentExpired() {
    return this.#agent.consentExpired(this.#consentExpiryMs);
  }

  /** Tear down the endpoint and the UDP socket (tests, shutdown). */
  async close() {
    this.#closed = true;
    this.#stopConsentLoop();
    this.turn?.stop();
    try {
      await this.#endpoint?.close();
    } catch {
      /* best effort */
    }
    try {
      this.#socket.close();
    } catch {
      /* already closed */
    }
  }
}
