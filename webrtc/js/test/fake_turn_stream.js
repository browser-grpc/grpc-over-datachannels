// Fake TURN server over TCP/TLS (test fixture): the stream
// counterpart of fake_turn.js — same 401 long-term-credential
// dance and permission enforcement, framed messages instead of
// datagrams (ChannelData padded to a 4-byte boundary). Run
// standalone for other stacks' tests:
//   node fake_turn_stream.js <tcp|tls>   -> prints "READY host:port"

import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import tls from "node:tls";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { StunAttribute, StunMessageType } from "../proto_gen.js";
import { StunMessage } from "../stun.js";
import { unwrapChannelData, unwrapDataIndication, wrapChannelData, xorAddressValue } from "../turn.js";
import { decodeAddressValue } from "../stun.js";

export const REALM = "dc.test";
const NONCE = "nonce-42";
export const USER = "dcuser";
export const PASS = "dcpass";
const key = () => crypto.createHash("md5").update(`${USER}:${REALM}:${PASS}`).digest();

function authorized(msg, raw) {
  if (msg.attr(StunAttribute.USERNAME)?.toString() !== USER) return false;
  return msg.checkIntegrity(raw, key());
}

function decodeXorAddress(msg, attrType) {
  const value = msg.attr(attrType);
  return value ? decodeAddressValue(value, msg.transactionId) : null;
}

class StreamAlloc {
  constructor(socket) {
    this.socket = socket;
    this.relayed = null;
    this.permissions = new Set(); // "addr:port"
    this.channels = new Map(); // channel -> "addr:port"
    this.peerChan = new Map(); // "addr:port" -> channel
  }

  write(frame, channelData) {
    let out = frame;
    if (channelData) {
      const pad = (4 - (frame.length % 4)) % 4;
      if (pad > 0) out = Buffer.concat([frame, Buffer.alloc(pad)]);
    }
    this.socket.write(out);
  }
}

function makeStreamTurn() {
  const stats = { refreshCount: 0, permReqCount: 0, bindCount: 0, chanData: 0 };
  const byRelay = new Map();
  let nextPort = 51100;

  function deliver(sender, destRelayed, data) {
    const dest = byRelay.get(`${destRelayed.address}:${destRelayed.port}`);
    if (!dest || !sender.relayed) return false;
    const senderKey = `${sender.relayed.address}:${sender.relayed.port}`;
    if (!dest.permissions.has(senderKey)) return false;
    const channel = dest.peerChan.get(senderKey);
    if (channel !== undefined) {
      dest.write(wrapChannelData(channel, data), true);
    } else {
      const ind = wrapSendIndicationLike(sender.relayed, data);
      dest.write(ind, false);
    }
    return true;
  }

  function wrapSendIndicationLike(peer, data) {
    const msg = new StunMessage(StunMessageType.DATA_INDICATION);
    msg.attrs.push([StunAttribute.XOR_PEER_ADDRESS, xorAddressValue(peer, msg.transactionId)]);
    msg.attrs.push([StunAttribute.DATA, Buffer.from(data)]);
    return msg.encode(null);
  }

  function onMessage(alloc, msg, raw) {
    if (msg.length >= 4 && msg[0] >= 0x40 && msg[0] <= 0x7f) {
      const framed = unwrapChannelData(msg);
      if (!framed) return;
      const peerKey = alloc.channels.get(framed.channel);
      if (!peerKey) return;
      const idx = peerKey.lastIndexOf(":");
      const dest = { address: peerKey.slice(0, idx), port: Number(peerKey.slice(idx + 1)) };
      if (deliver(alloc, dest, framed.data)) stats.chanData += 1;
      return;
    }
    const request = StunMessage.decode(msg);
    if (!request) return;
    const reply = (type, build, encodeKey) => {
      const resp = new StunMessage(type);
      resp.transactionId = Buffer.from(request.transactionId);
      build(resp);
      alloc.write(resp.encode(encodeKey), false);
    };
    if (request.type === StunMessageType.ALLOCATE_REQUEST) {
      if (!request.attr(StunAttribute.USERNAME) || !authorized(request, raw)) {
        reply(StunMessageType.ALLOCATE_ERROR, (resp) => {
          resp.attrs.push([StunAttribute.ERROR_CODE, Buffer.from([0, 0, 4, 1])]);
          resp.attrs.push([StunAttribute.REALM, Buffer.from(REALM)]);
          resp.attrs.push([StunAttribute.NONCE, Buffer.from(NONCE)]);
        }, null);
        return;
      }
      nextPort += 1;
      alloc.relayed = { address: "127.0.0.1", port: nextPort };
      byRelay.set(`${alloc.relayed.address}:${alloc.relayed.port}`, alloc);
      const mapped = { address: alloc.socket.remoteAddress, port: alloc.socket.remotePort };
      reply(StunMessageType.ALLOCATE_SUCCESS, (resp) => {
        resp.attrs.push([StunAttribute.XOR_RELAYED_ADDRESS, xorAddressValue(alloc.relayed, resp.transactionId)]);
        resp.attrs.push([StunAttribute.XOR_MAPPED_ADDRESS, xorAddressValue(mapped, resp.transactionId)]);
        resp.attrs.push([StunAttribute.LIFETIME, Buffer.from([0, 0, 2, 88])]);
      }, key());
    } else if (request.type === StunMessageType.REFRESH_REQUEST) {
      if (!authorized(request, raw)) return;
      stats.refreshCount += 1;
      reply(StunMessageType.REFRESH_SUCCESS, (resp) => {
        resp.attrs.push([StunAttribute.LIFETIME, Buffer.from([0, 0, 2, 88])]);
      }, key());
    } else if (request.type === StunMessageType.CREATE_PERMISSION_REQUEST) {
      if (!authorized(request, raw)) return;
      stats.permReqCount += 1;
      for (const [ty, value] of request.attrs) {
        if (ty !== StunAttribute.XOR_PEER_ADDRESS) continue;
        const peer = decodeAddressValue(value, request.transactionId);
        if (peer) alloc.permissions.add(`${peer.address}:${peer.port}`);
      }
      reply(StunMessageType.CREATE_PERMISSION_SUCCESS, () => {}, key());
    } else if (request.type === StunMessageType.CHANNEL_BIND_REQUEST) {
      if (!authorized(request, raw)) return;
      const chanValue = request.attr(StunAttribute.CHANNEL_NUMBER);
      const peer = decodeXorAddress(request, StunAttribute.XOR_PEER_ADDRESS);
      if (!chanValue || chanValue.length < 2 || !peer) return;
      const channel = chanValue.readUInt16BE(0);
      const peerKey = `${peer.address}:${peer.port}`;
      alloc.channels.set(channel, peerKey);
      alloc.peerChan.set(peerKey, channel);
      alloc.permissions.add(peerKey); // binding installs the permission
      stats.bindCount += 1;
      reply(StunMessageType.CHANNEL_BIND_SUCCESS, () => {}, key());
    } else if (request.type === StunMessageType.SEND_INDICATION) {
      const unwrapped = unwrapDataIndication(request);
      if (unwrapped) deliver(alloc, unwrapped.peer, unwrapped.data);
    }
  }

  function serveSocket(socket) {
    const alloc = new StreamAlloc(socket);
    let buf = Buffer.alloc(0);
    socket.on("data", (chunk) => {
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
          onMessage(alloc, msg, msg);
        } else {
          if (buf.length < 20) return;
          const length = buf.readUInt16BE(2);
          if (buf.length < 20 + length) return;
          const msg = buf.subarray(0, 20 + length);
          buf = buf.subarray(20 + length);
          onMessage(alloc, msg, msg);
        }
      }
    });
    socket.on("error", () => {});
  }

  return { stats, serveSocket };
}

export async function fakeTurnTcp() {
  const { stats, serveSocket } = makeStreamTurn();
  const server = net.createServer(serveSocket);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = `127.0.0.1:${server.address().port}`;
  return { server: address, stats, close: () => server.close() };
}

export async function fakeTurnTls(certStem = "turn_tls") {
  const { stats, serveSocket } = makeStreamTurn();
  const here = path.dirname(fileURLToPath(import.meta.url));
  const server = tls.createServer(
    {
      cert: fs.readFileSync(path.join(here, "fixtures", `${certStem}_cert.pem`)),
      key: fs.readFileSync(path.join(here, "fixtures", `${certStem}_key.pem`)),
      minVersion: "TLSv1.2",
    },
    serveSocket,
  );
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = `127.0.0.1:${server.address().port}`;
  return { server: address, stats, close: () => server.close() };
}

// Standalone mode for other stacks' tests.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const mode = process.argv[2] ?? "tcp";
  const fake =
    mode === "tls"
      ? await fakeTurnTls()
      : mode === "tls384"
        ? await fakeTurnTls("turn_tls384")
        : await fakeTurnTcp();
  console.log(`READY ${fake.server}`);
}
