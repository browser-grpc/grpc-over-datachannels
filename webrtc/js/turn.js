// TURN (RFC 5766) relay support: an Allocate over the peer's own
// UDP socket yields a relayed candidate; once the peer connects,
// its traffic for the nominated pair is wrapped in Send/Data
// indications through the allocation. Long-term credentials
// (401 REALM/NONCE challenge, MD5 key) are the only auth mode.
// Permissions are created per remote candidate at connect time
// and a channel is bound per peer address, so pair traffic uses
// 4-byte ChannelData framing (Send/Data indications remain the
// fallback for unbound addresses, and are accepted inbound). A
// background refresher re-issues CreatePermission, ChannelBind,
// and Refresh until the peer closes.
import crypto from "node:crypto";
import net from "node:net";
import tls from "node:tls";

import { StunAttribute, StunMessageType } from "./proto_gen.js";
import { decodeAddressValue, parseHostPort, parseIp, StunMessage, xorMappedAddress } from "./stun.js";

// TURN permissions and channel bindings name peer IP addresses;
// mDNS ".local" candidates can never be permissioned and are
// skipped (checks to them go direct, never via the relay).
const isIpPeer = (peer) => parseIp(peer.address) !== null;

// Encode an XOR-{PEER,RELAYED,MAPPED}-ADDRESS attribute value
// for a message carrying the given transaction ID (needed as
// part of the IPv6 XOR mask).
export function xorAddressValue(addr, transactionId) {
  return xorMappedAddress(addr, transactionId);
}

// Decode an XOR-encoded address attribute (PEER/RELAYED/MAPPED)
// of a message into {address, port}; null when malformed.
export function decodeXorAddress(msg, attrType) {
  return decodeAddressValue(msg.attr(attrType), msg.transactionId, true);
}

export function turnErrorCode(msg) {
  const value = msg.attr(StunAttribute.ERROR_CODE);
  if (!value || value.length < 4) return 0;
  return value[2] * 100 + value[3];
}

export function lifetimeOf(msg) {
  const value = msg.attr(StunAttribute.LIFETIME);
  if (!value || value.length < 4) return 600;
  const secs = value.readUInt32BE(0);
  return secs === 0 ? 600 : secs;
}

// One live TURN allocation.
export class TurnClient {
  constructor(server, username) {
    this.server = server; // {address, port}
    this.username = username;
    this.realm = null;
    this.nonce = null;
    this.key = null; // MD5(username:realm:password)
    this.relayed = null; // {address, port}
    this.mapped = null;
    this.lifetimeSecs = 600; // server-granted allocation lifetime
    this.peers = []; // permissioned peer addresses (for refresh)
    this.bindings = new Map(); // "addr:port" -> channel
    this.channels = new Map(); // channel -> {address, port}
    this.nextChan = 0x4000;
    this.waiters = new Map(); // tid hex -> resolve(msg)
    this.stream = null; // net.Socket for TCP/TLS allocations
    this._refreshTimer = null;
    this._stopped = false;
  }

  // How often permissions and the allocation are refreshed:
  // 80% of whichever expires first — permissions (300 s) or the
  // allocation lifetime.
  refreshIntervalMs() {
    let ms = this.lifetimeSecs * 800;
    if (!(ms > 0) || ms > 240000) ms = 240000;
    return Math.max(ms, 250);
  }

  // Background refresher: re-issues CreatePermission and
  // ChannelBind for the known peers and Refresh for the
  // allocation until stop().
  startRefresher(peer) {
    const tick = async () => {
      if (this._stopped) return;
      try {
        if (this.peers.length) {
          await createPermissionsFor(peer, this, this.peers).catch(() => {});
          await bindChannels(peer, this, this.peers).catch(() => {});
        }
        await refreshAllocation(peer, this).catch(() => {});
      } catch {
        /* best-effort: the next tick retries until expiry */
      }
      if (this._stopped) return;
      this._refreshTimer = setTimeout(tick, this.refreshIntervalMs());
      this._refreshTimer.unref?.();
    };
    this._refreshTimer = setTimeout(tick, this.refreshIntervalMs());
    this._refreshTimer.unref?.();
  }

  stop() {
    this._stopped = true;
    if (this._refreshTimer) clearTimeout(this._refreshTimer);
    this._refreshTimer = null;
    if (this.stream) {
      this.stream.destroy();
      this.stream = null;
    }
  }

  register(tidHex) {
    return new Promise((resolve) => this.waiters.set(tidHex, resolve));
  }

  // Delivers a control response to its waiter; false when the
  // message is not one we're waiting for.
  resolve(msg) {
    const tid = msg.transactionId.toString("hex");
    const waiter = this.waiters.get(tid);
    if (!waiter) return false;
    this.waiters.delete(tid);
    waiter(msg);
    return true;
  }
}

// Sends one TURN control message via sendRaw(buf, port, address)
// (the peer's direct socket path) and waits for its response,
// matched by transaction id in the peer's packet handler.
export async function turnRequest(peer, client, msg, key, timeoutMs) {
  const tid = msg.transactionId.toString("hex");
  const responsePromise = client.register(tid);
  peer.turnWrite(client, msg.encode(key), false);
  const resp = await Promise.race([
    responsePromise,
    new Promise((resolve) => setTimeout(() => resolve(null), timeoutMs)),
  ]);
  client.waiters.delete(tid);
  if (!resp) throw new Error("turn: timed out waiting for response");
  return resp;
}

// Frames inbound stream bytes into whole TURN messages and
// feeds each into the peer's TURN demux. STUN messages frame by
// header length; ChannelData by its length field plus padding
// to a 4-byte boundary (RFC 5766 section 4).
function attachStreamFraming(peer, client) {
  let buf = Buffer.alloc(0);
  client.stream.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 4) return;
      if (buf[0] >= 0x40 && buf[0] <= 0x7f) {
        const length = buf.readUInt16BE(2);
        const total = 4 + length;
        const padded = total + ((4 - (total % 4)) % 4);
        if (buf.length < padded) return;
        const msg = buf.subarray(0, total);
        buf = buf.subarray(padded);
        peer.onTurnPacket(msg);
      } else {
        if (buf.length < 20) return;
        const length = buf.readUInt16BE(2);
        if (buf.length < 20 + length) return;
        const msg = buf.subarray(0, 20 + length);
        buf = buf.subarray(20 + length);
        peer.onTurnPacket(msg);
      }
    }
  });
  client.stream.on("error", () => {});
}

// cfg.transport "tcp"/"tls": open the dedicated stream
// connection for the allocation ("tls" verifies the server
// certificate unless cfg.insecureSkipVerify is set;
// cfg.serverName overrides the verification name).
function isStreamTransport(cfg) {
  const transport = String(cfg.transport ?? "udp").toLowerCase();
  return transport === "tcp" || transport === "tls";
}

async function connectTurnStream(peer, client, cfg, timeoutMs) {
  const transport = String(cfg.transport).toLowerCase();
  const { address: host, port } = client.server;
  const socket =
    transport === "tls"
      ? tls.connect({
          host,
          port,
          // Node rejects IP literals as servername; leaving it
          // unset makes verification use the IP SAN instead.
          servername: cfg.serverName ?? (net.isIP(host) ? undefined : host),
          rejectUnauthorized: !cfg.insecureSkipVerify,
          minVersion: "TLSv1.2",
        })
      : net.connect({ host, port });
  client.stream = socket;
  attachStreamFraming(peer, client);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("turn: stream connect timed out"));
    }, timeoutMs);
    const readyEvent = transport === "tls" ? "secureConnect" : "connect";
    socket.once(readyEvent, () => {
      clearTimeout(timer);
      resolve();
    });
    socket.once("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

// Runs the Allocate handshake (with the 401 long-term-credential
// dance when demanded) and returns the populated TurnClient.
// cfg is {address, username, password, transport?, serverName?,
// insecureSkipVerify?}; transport "tcp"/"tls" runs the
// allocation over a dedicated stream connection instead of the
// peer's UDP socket (relayed traffic still reaches peers over
// UDP — REQUESTED-TRANSPORT stays 17).
export async function allocateTurn(peer, cfg, timeoutMs = 2000) {
  const server = parseHostPort(cfg.address, 3478);
  if (!server) throw new Error(`turn: bad server address: ${cfg.address}`);
  const transport = String(cfg.transport ?? "udp").toLowerCase();
  if (!["udp", "tcp", "tls"].includes(transport)) {
    throw new Error(`turn: unsupported transport ${JSON.stringify(cfg.transport)}`);
  }
  const client = new TurnClient(server, cfg.username);
  // Publish before the first request: the peer demultiplexes TURN
  // control responses (and later Data indications) by sender
  // matching its current client; the stream framing feeds the
  // same demux for TCP/TLS.
  peer.turn = client;
  try {
    if (isStreamTransport(cfg)) {
      await connectTurnStream(peer, client, cfg, timeoutMs);
    }
  } catch (err) {
    if (peer.turn === client) peer.turn = null;
    client.stop();
    throw err;
  }

  const build = (auth) => {
    const msg = new StunMessage(StunMessageType.ALLOCATE_REQUEST);
    msg.attrs.push([StunAttribute.REQUESTED_TRANSPORT, Buffer.from([17, 0, 0, 0])]);
    if (cfg.requestIpv6Relay) {
      // REQUESTED-ADDRESS-FAMILY: family 2 (IPv6). Some servers
      // (coturn with only an IPv6 relay address) reject
      // allocations that do not request it with error 440.
      msg.attrs.push([StunAttribute.REQUESTED_ADDRESS_FAMILY, Buffer.from([2, 0, 0, 0])]);
    }
    if (auth) {
      msg.attrs.push([StunAttribute.USERNAME, Buffer.from(cfg.username)]);
      msg.attrs.push([StunAttribute.REALM, Buffer.from(client.realm)]);
      msg.attrs.push([StunAttribute.NONCE, Buffer.from(client.nonce)]);
    }
    return msg;
  };

  let resp = await turnRequest(peer, client, build(false), null, timeoutMs);
  if (resp.type === StunMessageType.ALLOCATE_ERROR && turnErrorCode(resp) === 401) {
    client.realm = resp.attr(StunAttribute.REALM)?.toString() ?? "";
    client.nonce = resp.attr(StunAttribute.NONCE)?.toString() ?? "";
    client.key = crypto.createHash("md5").update(`${cfg.username}:${client.realm}:${cfg.password}`).digest();
    resp = await turnRequest(peer, client, build(true), client.key, timeoutMs);
  }
  if (resp.type !== StunMessageType.ALLOCATE_SUCCESS) {
    throw new Error(`turn: allocate failed (type ${resp.type}, code ${turnErrorCode(resp)})`);
  }
  client.relayed = decodeXorAddress(resp, StunAttribute.XOR_RELAYED_ADDRESS);
  client.mapped = decodeXorAddress(resp, StunAttribute.XOR_MAPPED_ADDRESS);
  if (!client.relayed) throw new Error("turn: allocate success without XOR-RELAYED-ADDRESS");
  client.lifetimeSecs = lifetimeOf(resp);
  client.startRefresher(peer);
  return client;
}

// Binds one channel per peer address (RFC 5766 section 9; a
// binding also installs the permission). Best-effort per
// address: on failure traffic keeps using Send indications.
export async function bindChannels(peer, client, peers, timeoutMs = 2000) {
  for (const remote of peers) {
    if (!isIpPeer(remote)) continue;
    const key = `${remote.address}:${remote.port}`;
    let channel = client.bindings.get(key);
    if (channel === undefined) channel = client.nextChan++;
    const msg = new StunMessage(StunMessageType.CHANNEL_BIND_REQUEST);
    const chanAttr = Buffer.alloc(4);
    chanAttr.writeUInt16BE(channel, 0);
    msg.attrs.push([StunAttribute.CHANNEL_NUMBER, chanAttr]);
    msg.attrs.push([StunAttribute.XOR_PEER_ADDRESS, xorAddressValue(remote, msg.transactionId)]);
    msg.attrs.push([StunAttribute.USERNAME, Buffer.from(client.username)]);
    msg.attrs.push([StunAttribute.REALM, Buffer.from(client.realm)]);
    msg.attrs.push([StunAttribute.NONCE, Buffer.from(client.nonce)]);
    try {
      const resp = await turnRequest(peer, client, msg, client.key, timeoutMs);
      if (resp.type !== StunMessageType.CHANNEL_BIND_SUCCESS) continue;
    } catch {
      continue;
    }
    client.bindings.set(key, channel);
    client.channels.set(channel, { address: remote.address, port: remote.port });
  }
}

// Frames one datagram as ChannelData (RFC 5766 section 11):
// channel number, length, payload (no padding over UDP).
export function wrapChannelData(channel, data) {
  const buf = Buffer.from(data);
  const out = Buffer.alloc(4 + buf.length);
  out.writeUInt16BE(channel, 0);
  out.writeUInt16BE(buf.length, 2);
  buf.copy(out, 4);
  return out;
}

// Parses a ChannelData message into {channel, data}, tolerating
// trailing padding beyond the length field; null when malformed.
export function unwrapChannelData(msg) {
  if (msg.length < 4) return null;
  const length = msg.readUInt16BE(2);
  if (4 + length > msg.length) return null;
  return { channel: msg.readUInt16BE(0), data: msg.subarray(4, 4 + length) };
}

// Extends the allocation (RFC 5766 section 7), requesting the
// default 600 s and adopting the granted lifetime.
export async function refreshAllocation(peer, client, timeoutMs = 2000) {
  const msg = new StunMessage(StunMessageType.REFRESH_REQUEST);
  const lifetime = Buffer.alloc(4);
  lifetime.writeUInt32BE(600, 0);
  msg.attrs.push([StunAttribute.LIFETIME, lifetime]);
  msg.attrs.push([StunAttribute.USERNAME, Buffer.from(client.username)]);
  msg.attrs.push([StunAttribute.REALM, Buffer.from(client.realm)]);
  msg.attrs.push([StunAttribute.NONCE, Buffer.from(client.nonce)]);
  const resp = await turnRequest(peer, client, msg, client.key, timeoutMs);
  if (resp.type !== StunMessageType.REFRESH_SUCCESS) {
    throw new Error(`turn: refresh failed (type ${resp.type})`);
  }
  client.lifetimeSecs = lifetimeOf(resp);
}

// Installs relay permissions for the peer's remote candidates so
// the server forwards our relayed traffic (and delivers the
// peer's). Best-effort, like an unreachable candidate. The
// permissioned addresses are remembered for the refresher.
export async function createPermissions(peer, client, candidates, timeoutMs = 2000) {
  const seen = new Set();
  const peers = [];
  for (const cand of candidates) {
    if (!isIpPeer(cand)) continue;
    const key = `${cand.address}:${cand.port}`;
    if (seen.has(key)) continue;
    seen.add(key);
    peers.push({ address: cand.address, port: cand.port });
  }
  if (peers.length === 0) return;
  // Merge (never replace): candidates trickled in earlier may
  // already have added peers the refresher must keep alive.
  for (const p of peers) {
    if (!client.peers.some((q) => q.address === p.address && q.port === p.port)) {
      client.peers.push(p);
    }
  }
  await createPermissionsFor(peer, client, peers, timeoutMs).catch(() => {});
}

// Adds one peer address trickled in after the connect-time
// snapshot: remembers it for the refresher, creates its
// permission, and binds a channel. Best-effort and idempotent;
// non-IP (mDNS) addresses are ignored until resolved.
export async function addTurnPeer(peer, client, addr, timeoutMs = 2000) {
  if (!isIpPeer(addr)) return;
  if (client.peers.some((q) => q.address === addr.address && q.port === addr.port)) return;
  client.peers.push({ address: addr.address, port: addr.port });
  await createPermissionsFor(peer, client, [addr], timeoutMs).catch(() => {});
  await bindChannels(peer, client, [addr], timeoutMs).catch(() => {});
}

// Sends one CreatePermission request for the given peers.
export async function createPermissionsFor(peer, client, peers, timeoutMs = 2000) {
  const msg = new StunMessage(StunMessageType.CREATE_PERMISSION_REQUEST);
  for (const cand of peers) {
    if (!isIpPeer(cand)) continue;
    msg.attrs.push([StunAttribute.XOR_PEER_ADDRESS, xorAddressValue(cand, msg.transactionId)]);
  }
  msg.attrs.push([StunAttribute.USERNAME, Buffer.from(client.username)]);
  msg.attrs.push([StunAttribute.REALM, Buffer.from(client.realm)]);
  msg.attrs.push([StunAttribute.NONCE, Buffer.from(client.nonce)]);
  await turnRequest(peer, client, msg, client.key, timeoutMs);
}

// Wraps one datagram in a Send indication to the peer.
export function wrapSendIndication(client, data, remote) {
  const msg = new StunMessage(StunMessageType.SEND_INDICATION);
  msg.attrs.push([StunAttribute.XOR_PEER_ADDRESS, xorAddressValue(remote, msg.transactionId)]);
  msg.attrs.push([StunAttribute.DATA, Buffer.from(data)]);
  return msg.encode(null);
}

// Extracts {peer, data} from a Data indication.
export function unwrapDataIndication(msg) {
  const peer = decodeXorAddress(msg, StunAttribute.XOR_PEER_ADDRESS);
  const data = msg.attr(StunAttribute.DATA);
  if (!peer || !data) return null;
  return { peer, data };
}
