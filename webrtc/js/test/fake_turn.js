// Fake TURN server (RFC 5766 fixture, loopback): Allocate with
// long-term credential auth, CreatePermission, Send/Data
// indication relaying between allocations, plus direct delivery
// to relayed ports. Shared by the JS TURN tests and the browser
// TURN test (real browser TURN clients run against it).

import crypto from "node:crypto";
import dgram from "node:dgram";
import { StunMessage } from "../stun.js";
import { StunAttribute, StunMessageType } from "../proto_gen.js";
import { decodeXorAddress, unwrapChannelData, wrapChannelData, xorAddressValue } from "../turn.js";
import { xorMappedAddress } from "../stun.js";

export const REALM = "dc.test";
const NONCE = "nonce-42";
export const USER = "dcuser";
export const PASS = "dcpass";
const key = () => crypto.createHash("md5").update(`${USER}:${REALM}:${PASS}`).digest();

function authorized(msg, raw) {
  if (msg.attr(StunAttribute.USERNAME)?.toString() !== USER) return false;
  return msg.checkIntegrity(raw, key());
}

// Options: lifetimeSeconds / permissionSeconds shorten the
// enforced allocation and permission expiries (defaults are the
// RFC values) so client refresh behavior is observable in tests.
export async function fakeTurnServer({ lifetimeSeconds = 600, permissionSeconds = 300 } = {}) {
  const socket = dgram.createSocket("udp4");
  const byClient = new Map();
  const byRelay = new Map();
  const relaySockets = [];
  const stats = { refreshCount: 0, permReqCount: 0, bindCount: 0, chanData: 0 };
  const lifetimeAttr = () => {
    const buf = Buffer.alloc(4);
    buf.writeUInt32BE(lifetimeSeconds, 0);
    return buf;
  };
  const live = (alloc) => alloc && Date.now() < alloc.expiresAt;
  const permOK = (alloc, key) => {
    const expiry = alloc.permissions.get(key);
    return expiry !== undefined && Date.now() < expiry;
  };

  // Deliver payload to dest's client: ChannelData when dest
  // bound a channel to the sender address, else Data indication.
  function deliver(dest, senderAddr, data) {
    const channel = dest.peerChan.get(`${senderAddr.address}:${senderAddr.port}`);
    if (channel !== undefined) {
      socket.send(wrapChannelData(channel, data), dest.client.port, dest.client.address);
      return;
    }
    const ind = new StunMessage(StunMessageType.DATA_INDICATION);
    ind.attrs.push([StunAttribute.XOR_PEER_ADDRESS, xorAddressValue(senderAddr, ind.transactionId)]);
    ind.attrs.push([StunAttribute.DATA, Buffer.from(data)]);
    socket.send(ind.encode(null), dest.client.port, dest.client.address);
  }

  function listenRelay(alloc, onReady) {
    const relaySocket = dgram.createSocket("udp4");
    alloc.relaySocket = relaySocket;
    relaySockets.push(relaySocket);
    relaySocket.on("message", (data, rinfo) => {
      const src = { address: rinfo.address, port: rinfo.port };
      if (!live(alloc) || !permOK(alloc, `${src.address}:${src.port}`)) return;
      deliver(alloc, src, data);
    });
    // Ephemeral relay port: parallel test files each run a fake
    // server in the same network namespace, so a fixed range
    // collides (EADDRINUSE) across processes.
    relaySocket.bind(0, alloc.relayed.address, () => {
      alloc.relayed.port = relaySocket.address().port;
      byRelay.set(`${alloc.relayed.address}:${alloc.relayed.port}`, alloc);
      onReady?.();
    });
  }

  socket.on("message", (msg, rinfo) => {
    const raw = Buffer.from(msg);
    const src0 = { address: rinfo.address, port: rinfo.port };
    if (raw.length >= 4 && raw[0] >= 0x40 && raw[0] <= 0x7f) {
      const framed = unwrapChannelData(raw);
      if (!framed) return;
      const sender = byClient.get(`${src0.address}:${src0.port}`);
      if (!live(sender)) return;
      const peerKey = sender.channels.get(framed.channel);
      if (!peerKey) return;
      const dest = byRelay.get(peerKey);
      if (!dest) {
        // Direct (non-TURN) peer: deliver from the relay socket.
        const cut = peerKey.lastIndexOf(":");
        const address = peerKey.slice(0, cut);
        const port = Number(peerKey.slice(cut + 1));
        if (live(sender) && sender.relaySocket) sender.relaySocket.send(framed.data, port, address);
        return;
      }
      if (!live(dest) || !permOK(dest, `${sender.relayed.address}:${sender.relayed.port}`)) return;
      stats.chanData += 1;
      deliver(dest, sender.relayed, framed.data);
      return;
    }
    const request = StunMessage.decode(raw);
    if (!request) return;
    const src = { address: rinfo.address, port: rinfo.port };
    if (request.type === StunMessageType.BINDING_REQUEST) {
      // TURN servers are also STUN servers; some clients (Firefox)
      // probe with a Binding request before allocating.
      const resp = new StunMessage(StunMessageType.BINDING_SUCCESS);
      resp.transactionId = Buffer.from(request.transactionId);
      resp.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, xorMappedAddress(src, request.transactionId)]);
      socket.send(resp.encode(null), src.port, src.address);
      return;
    }
    if (request.type === StunMessageType.ALLOCATE_REQUEST) {
      if (!request.attr(StunAttribute.USERNAME) || !authorized(request, raw)) {
        const resp = new StunMessage(StunMessageType.ALLOCATE_ERROR);
        resp.transactionId = Buffer.from(request.transactionId);
        resp.attrs.push([StunAttribute.ERROR_CODE, Buffer.from([0, 0, 4, 1])]);
        resp.attrs.push([StunAttribute.REALM, Buffer.from(REALM)]);
        resp.attrs.push([StunAttribute.NONCE, Buffer.from(NONCE)]);
        resp.attrs.push([StunAttribute.SOFTWARE, Buffer.from("dc-webrtc-fake")]);
        socket.send(resp.encode(null), src.port, src.address);
        return;
      }
      const relayed = { address: "127.0.0.1", port: 0 };
      const alloc = {
        client: src,
        relayed,
        permissions: new Map(), // peer key -> expiry (ms epoch)
        expiresAt: Date.now() + lifetimeSeconds * 1000,
        channels: new Map(), // channel -> peer key
        peerChan: new Map(), // peer key -> channel
      };
      byClient.set(`${src.address}:${src.port}`, alloc);
      listenRelay(alloc, () => {
        const resp = new StunMessage(StunMessageType.ALLOCATE_SUCCESS);
        resp.transactionId = Buffer.from(request.transactionId);
        resp.attrs.push([StunAttribute.XOR_RELAYED_ADDRESS, xorAddressValue(relayed, resp.transactionId)]);
        resp.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, xorAddressValue(src, resp.transactionId)]);
        resp.attrs.push([StunAttribute.LIFETIME, lifetimeAttr()]);
        resp.attrs.push([StunAttribute.SOFTWARE, Buffer.from("dc-webrtc-fake")]);
        socket.send(resp.encode(key()), src.port, src.address);
      });
    } else if (request.type === StunMessageType.REFRESH_REQUEST) {
      const alloc = byClient.get(`${src.address}:${src.port}`);
      if (!alloc || !authorized(request, raw)) return;
      if (!live(alloc)) {
        const resp = new StunMessage(StunMessageType.REFRESH_ERROR);
        resp.transactionId = Buffer.from(request.transactionId);
        resp.attrs.push([StunAttribute.ERROR_CODE, Buffer.from([0, 0, 4, 37])]); // 437
        socket.send(resp.encode(key()), src.port, src.address);
        return;
      }
      alloc.expiresAt = Date.now() + lifetimeSeconds * 1000;
      stats.refreshCount += 1;
      const resp = new StunMessage(StunMessageType.REFRESH_SUCCESS);
      resp.transactionId = Buffer.from(request.transactionId);
      resp.attrs.push([StunAttribute.LIFETIME, lifetimeAttr()]);
      socket.send(resp.encode(key()), src.port, src.address);
    } else if (request.type === StunMessageType.CHANNEL_BIND_REQUEST) {
      const alloc = byClient.get(`${src.address}:${src.port}`);
      if (!live(alloc) || !authorized(request, raw)) return;
      const chanValue = request.attr(StunAttribute.CHANNEL_NUMBER);
      const peer = decodeXorAddress(request, StunAttribute.XOR_PEER_ADDRESS);
      if (!chanValue || chanValue.length < 2 || !peer) return;
      const channel = chanValue.readUInt16BE(0);
      const peerKey = `${peer.address}:${peer.port}`;
      // A binding also installs the permission (RFC 5766 §9).
      alloc.channels.set(channel, peerKey);
      alloc.peerChan.set(peerKey, channel);
      alloc.permissions.set(peerKey, Date.now() + permissionSeconds * 1000);
      stats.bindCount += 1;
      const resp = new StunMessage(StunMessageType.CHANNEL_BIND_SUCCESS);
      resp.transactionId = Buffer.from(request.transactionId);
      socket.send(resp.encode(key()), src.port, src.address);
    } else if (request.type === StunMessageType.CREATE_PERMISSION_REQUEST) {
      const alloc = byClient.get(`${src.address}:${src.port}`);
      if (!alloc || !authorized(request, raw)) return;
      stats.permReqCount += 1;
      const expiry = Date.now() + permissionSeconds * 1000;
      for (const [ty, value] of request.attrs) {
        if (ty !== StunAttribute.XOR_PEER_ADDRESS) continue;
        const probe = new StunMessage(request.type);
        probe.transactionId = Buffer.from(request.transactionId);
        probe.attrs.push([ty, value]);
        const peer = decodeXorAddress(probe, StunAttribute.XOR_PEER_ADDRESS);
        if (peer) alloc.permissions.set(`${peer.address}:${peer.port}`, expiry);
      }
      const resp = new StunMessage(StunMessageType.CREATE_PERMISSION_SUCCESS);
      resp.transactionId = Buffer.from(request.transactionId);
      socket.send(resp.encode(key()), src.port, src.address);
    } else if (request.type === StunMessageType.SEND_INDICATION) {
      const peer = decodeXorAddress(request, StunAttribute.XOR_PEER_ADDRESS);
      const data = request.attr(StunAttribute.DATA);
      if (!peer || !data) return;
      const sender = byClient.get(`${src.address}:${src.port}`);
      const dest = byRelay.get(`${peer.address}:${peer.port}`);
      if (!live(sender)) return;
      if (!dest) {
        // Direct (non-TURN) peer: deliver from the relay socket.
        if (sender.relaySocket) sender.relaySocket.send(data, peer.port, peer.address);
        return;
      }
      if (!live(dest)) return;
      if (!permOK(dest, `${sender.relayed.address}:${sender.relayed.port}`)) return;
      deliver(dest, sender.relayed, data);
    }
  });
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  return {
    server: `127.0.0.1:${socket.address().port}`,
    stats,
    close: () => {
      socket.close();
      for (const s of relaySockets) s.close();
    },
  };
}

