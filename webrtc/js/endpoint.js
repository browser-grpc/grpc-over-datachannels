// DataChannel endpoint: owns a DTLS connection and the SCTP
// association, exposes DCEP channels with an RTCDataChannel-shaped
// surface (send / message events) so the grpc-dc JS runtime can run on
// it unchanged. Mirrors webrtc/rust/src/endpoint.rs.

import {
  PPID_BINARY,
  PPID_BINARY_EMPTY,
  PPID_DCEP,
  PPID_STRING,
  PPID_STRING_EMPTY,
  decodeOpen,
  defaultParams,
  encodeAck,
  encodeOpen,
  isAck,
  sendOptionsOf,
} from "./dcep.js";
import { Association, SCTP_PORT } from "./sctp.js";

export class DataChannel {
  constructor(endpoint, stream, params) {
    this._endpoint = endpoint;
    this.id = stream;
    this.label = params.label ?? "";
    this.protocol = params.protocol ?? "";
    this.params = params;
    this.readyState = "open";
    this._onmessage = null;
    this.onclose = null;
    this._listeners = new Map();
    // Messages that arrive before any handler is registered are queued,
    // never dropped (matches native RTCDataChannel handler timing).
    this._pending = [];
    Object.defineProperty(this, "onmessage", {
      get: () => this._onmessage,
      set: (fn) => {
        this._onmessage = fn;
        this._flushPending();
      },
    });
  }

  _flushPending() {
    if (!this._onmessage && !(this._listeners.get("message") ?? []).length) return;
    const pending = this._pending.splice(0);
    for (const event of pending) this._deliver(event);
  }

  _deliver(event) {
    this._onmessage?.(event);
    for (const fn of [...(this._listeners.get("message") ?? [])]) fn(event);
  }

  /** RTCDataChannel-shaped send: string or binary (Uint8Array/Buffer). */
  send(data) {
    if (typeof data === "string") {
      this._endpoint._sendData(this, Buffer.from(data, "utf8"), true);
    } else {
      this._endpoint._sendData(this, Buffer.from(data), false);
    }
  }

  // Signal an SCTP stream reset to the peer (RFC 8831 §6.4);
  // readyState is "closing" until both directions complete,
  // then "closed" and onclose fires via _emitClose.
  close() {
    if (this.readyState !== "open") return;
    this.readyState = "closing";
    this._endpoint._closeChannel(this);
  }

  _emitClose() {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    this.onclose?.({});
    for (const fn of [...(this._listeners.get("close") ?? [])]) fn({});
  }

  addEventListener(type, fn) {
    if (!this._listeners.has(type)) this._listeners.set(type, []);
    this._listeners.get(type).push(fn);
    if (type === "message") this._flushPending();
  }

  removeEventListener(type, fn) {
    const list = this._listeners.get(type) ?? [];
    this._listeners.set(type, list.filter((f) => f !== fn));
  }

  _emitMessage(data, isText) {
    const event = { data: isText ? data.toString("utf8") : data };
    if (!this._onmessage && !(this._listeners.get("message") ?? []).length) {
      this._pending.push(event);
      return;
    }
    this._deliver(event);
  }
}

export class DcEndpoint {
  /**
   * @param dtls an established DtlsConnection
   * @param role "client" (DTLS client: opens even streams, sends INIT)
   *             or "server" (DTLS server: odd streams)
   */
  constructor(dtls, role, { localPort = SCTP_PORT } = {}) {
    this.dtls = dtls;
    this.role = role;
    this.assoc = role === "client" ? Association.newClient(localPort) : Association.newServer(localPort);
    this.channels = new Map();
    this.nextStream = role === "client" ? 0 : 1;
    // Channels opened by the peer before a handler is registered
    // are queued and delivered on assignment, never dropped
    // (matches native RTCPeerConnection ondatachannel timing:
    // the event cannot fire before the current task yields).
    this._onchannel = null;
    this._pendingChannels = [];
    Object.defineProperty(this, "onchannel", {
      get: () => this._onchannel,
      set: (fn) => {
        this._onchannel = fn;
        if (fn) {
          const pending = this._pendingChannels.splice(0);
          for (const channel of pending) fn(channel);
        }
      },
    });
    this._startMs = Date.now();
    this._closed = false;
    if (role === "client") {
      const init = this.assoc.connect(this._now());
      this.dtls.sendApp(init).catch(() => {});
    }
    this._pumpTask = this._pump();
  }

  _now() {
    return Date.now() - this._startMs;
  }

  openChannel(params = {}) {
    const full = { ...defaultParams(), ...params };
    const stream = this.nextStream;
    this.nextStream += 2;
    const channel = new DataChannel(this, stream, full);
    this.channels.set(stream, channel);
    const packets = this.assoc.sendData(stream, PPID_DCEP, encodeOpen(full), {}, this._now());
    this._sendPackets(packets);
    return channel;
  }

  _sendPackets(packets) {
    for (const p of packets) {
      this.dtls.sendApp(p).catch(() => {});
    }
  }

  _sendData(channel, data, isText) {
    const ppid = isText
      ? data.length === 0
        ? PPID_STRING_EMPTY
        : PPID_STRING
      : data.length === 0
        ? PPID_BINARY_EMPTY
        : PPID_BINARY;
    const packets = this.assoc.sendData(
      channel.id,
      ppid,
      data,
      sendOptionsOf(channel.params),
      this._now(),
    );
    this._sendPackets(packets);
  }

  _closeChannel(channel) {
    // Keep the channel registered until the reset completes so
    // in-flight messages still deliver; _onSctpEvent removes it.
    this._sendPackets(this.assoc.closeStream(channel.id));
  }

  async _pump() {
    while (!this._closed) {
      let packet = null;
      try {
        packet = await this.dtls.recvAppTimeout(10);
      } catch {
        break;
      }
      if (packet !== null) {
        const { packets, events } = this.assoc.handlePacket(packet, this._now());
        this._sendPackets(packets);
        for (const event of events) this._onSctpEvent(event);
      }
      const tick = this.assoc.tick(this._now());
      this._sendPackets(tick.packets);
      for (const event of tick.events) this._onSctpEvent(event);
    }
  }

  _onSctpEvent(event) {
    if (event.type === "stream-reset") {
      const channel = this.channels.get(event.stream);
      this.channels.delete(event.stream);
      channel?._emitClose();
      return;
    }
    if (event.type !== "data") return;
    const { stream, ppid, payload } = event;
    if (ppid === PPID_DCEP) {
      if (isAck(payload)) return;
      const params = decodeOpen(payload);
      if (!params) return;
      const channel = new DataChannel(this, stream, params);
      this.channels.set(stream, channel);
      const packets = this.assoc.sendData(stream, PPID_DCEP, encodeAck(), {}, this._now());
      this._sendPackets(packets);
      if (this._onchannel) this._onchannel(channel);
      else this._pendingChannels.push(channel);
      return;
    }
    const channel = this.channels.get(stream);
    if (!channel) return;
    const isText = ppid === PPID_STRING || ppid === PPID_STRING_EMPTY;
    channel._emitMessage(payload, isText);
  }

  async close() {
    this._closed = true;
    const packets = this.assoc.close(this._now());
    this._sendPackets(packets);
  }
}
