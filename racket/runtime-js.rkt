#lang racket

;;; runtime-js.rkt — the js gRPC runtime, emitted by metagen.rkt.
;;;
;;; The runtime files under the language tree are GENERATED from the
;;; bodies below plus fragments recursively expanded from spec.rkt's
;;; frame/status tables (see the dispatch generator). Do not edit the
;;; generated runtime files; edit here and run `make generate`.
;;; (Bodies were authored in-language and are kept verbatim so the
;;; generated output stays byte-reviewable in git diffs.)

(require "spec.rkt")
(provide emit-js-runtime-files)

(define js-codec-body
#<<GRPC_RUNTIME_EOF
// Frame codec: one DataChannel message == one frame (SPEC.md).
// type:u8 | stream_id:u32be | payload_len:u32be | payload

import { FrameType, StatusCode, StatusName } from "../wire_gen.js";

export { FrameType, StatusCode, StatusName };

export const HEADER_LEN = 9;
export const MAX_DATA_PAYLOAD = 16 * 1024 * 1024;

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export class StatusError extends Error {
  constructor(code, message = "") {
    super(`${StatusName[code] ?? `CODE_${code}`}: ${message}`);
    this.name = "StatusError";
    this.code = code;
    // The raw status message for the wire: Error.message carries
    // a "NAME: " display prefix that must not leak into status
    // frames (peers would see it doubled).
    this.statusMessage = message;
  }
  static ok() {
    return new StatusError(StatusCode.OK, "");
  }
  static unimplemented(message) {
    return new StatusError(StatusCode.UNIMPLEMENTED, message);
  }
  static internal(message) {
    return new StatusError(StatusCode.INTERNAL, message);
  }
  static unavailable(message) {
    return new StatusError(StatusCode.UNAVAILABLE, message);
  }
  static invalidArgument(message) {
    return new StatusError(StatusCode.INVALID_ARGUMENT, message);
  }
}

export function encodeFrame(type, streamId, payload = new Uint8Array(0)) {
  if (!(type in FrameTypeByValue)) {
    throw StatusError.invalidArgument(`unknown frame type ${type}`);
  }
  if (type === FrameType.DATA && payload.length > MAX_DATA_PAYLOAD) {
    throw new StatusError(StatusCode.RESOURCE_EXHAUSTED, "DATA payload exceeds 16 MiB");
  }
  const out = new Uint8Array(HEADER_LEN + payload.length);
  const view = new DataView(out.buffer);
  view.setUint8(0, type);
  view.setUint32(1, streamId, false);
  view.setUint32(5, payload.length, false);
  out.set(payload, HEADER_LEN);
  return out;
}

const FrameTypeByValue = Object.fromEntries(
  Object.entries(FrameType).map(([k, v]) => [v, k]),
);

export function decodeFrame(data) {
  const bytes = asUint8Array(data);
  if (bytes.length < HEADER_LEN) {
    throw StatusError.invalidArgument(`frame shorter than 9-byte header: ${bytes.length} bytes`);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const type = view.getUint8(0);
  const streamId = view.getUint32(1, false);
  const len = view.getUint32(5, false);
  if (len !== bytes.length - HEADER_LEN) {
    throw StatusError.invalidArgument(
      `payload length ${len} does not match message size ${bytes.length}`,
    );
  }
  return { type, streamId, payload: bytes.slice(HEADER_LEN) };
}

export function asUint8Array(data) {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  throw StatusError.internal("data channel message is not binary");
}

export function headersFrame(streamId, path, metadata = {}) {
  const body = path === null ? { metadata } : { path, metadata };
  return encodeFrame(FrameType.HEADERS, streamId, textEncoder.encode(JSON.stringify(body)));
}

// gRPC timeout grammar (grpc-timeout metadata): <digits><unit>,
// units H/M/S/m/u/n (at most 8 digits). Encoding uses
// milliseconds (seconds past the digit limit), rounded up so a
// deadline never shrinks in propagation.
const TIMEOUT_UNITS_MS = { H: 3600000, M: 60000, S: 1000, m: 1, u: 0.001, n: 0.000001 };

export function encodeTimeout(timeoutMs) {
  const ms = Math.ceil(timeoutMs);
  if (ms <= 99999999) return `${ms}m`;
  return `${Math.ceil(timeoutMs / 1000)}S`;
}

export function parseTimeout(text) {
  if (typeof text !== "string" || text.length < 2) return null;
  const unit = TIMEOUT_UNITS_MS[text[text.length - 1]];
  const digits = text.slice(0, -1);
  if (unit === undefined || digits.length > 8 || !/^\d+$/.test(digits)) return null;
  return Number(digits) * unit;
}

// Status frames (TRAILERS/RST) carry {code, message} and, when
// the call produced trailing metadata, a metadata member with
// the same JSON shape as HEADERS metadata (SPEC.md). Peers that
// predate trailing metadata ignore the member.
export function statusFrame(frameType, streamId, status, trailers = undefined) {
  const md = trailers ?? status.trailers;
  const body = { code: status.code, message: status.statusMessage ?? status.message ?? "" };
  if (md && Object.keys(md).length > 0) body.metadata = md;
  return encodeFrame(frameType, streamId, textEncoder.encode(JSON.stringify(body)));
}

export function parseHeaders(payload) {
  try {
    const parsed = JSON.parse(textDecoder.decode(payload));
    return { path: parsed.path ?? null, metadata: parsed.metadata ?? {} };
  } catch {
    throw StatusError.invalidArgument("malformed HEADERS payload");
  }
}

export function parseStatus(payload) {
  try {
    const parsed = JSON.parse(textDecoder.decode(payload));
    const status = new StatusError(parsed.code ?? 2, parsed.message ?? "");
    status.trailers = parsed.metadata ?? {};
    return status;
  } catch {
    return StatusError.internal("malformed status payload");
  }
}

export function toHex(bytes) {
  return [...asUint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function fromHex(hex) {
  const clean = hex.replace(/\s+/g, "");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

// --- Homegrown tracing@@TRACING_BETA@@ (W3C traceparent propagation) -------------
// Dormant until setTracer() registers an observer with
// onStart(kind, method, traceId, spanId, parentSpanId) and
// onEnd(kind, method, traceId, spanId, statusName). Generated code
// stays dependency-free: sampling and export are the app's problem.

let tracer = null;

export function setTracer(t) {
  tracer = t;
}

export function getTracer() {
  return tracer;
}

let traceFilter = [];

// Restrict traced methods: ';'-separated paths, a trailing '*'
// means prefix match ('/echo.Echo/*'). Empty = trace all.
export function setTraceFilter(patterns) {
  traceFilter = patterns.split(";").filter(Boolean);
}

function traceAllowed(method) {
  if (traceFilter.length === 0) return true;
  return traceFilter.some((p) =>
    p.endsWith("*") ? method.startsWith(p.slice(0, -1)) : method === p
  );
}

function randomHex(bytes) {
  const buf = new Uint8Array(bytes);
  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(buf);
  } else {
    for (let i = 0; i < bytes; i++) buf[i] = Math.floor(Math.random() * 256);
  }
  return toHex(buf);
}

export function formatTraceparent(traceId, spanId, sampled = true) {
  return `00-${traceId}-${spanId}-${sampled ? "01" : "00"}`;
}

export function parseTraceparent(value) {
  if (typeof value !== "string") return null;
  const parts = value.split("-");
  if (parts.length !== 4) return null;
  const [, traceId, spanId, flags] = parts;
  if (!/^[0-9a-f]{32}$/.test(traceId) || !/^[0-9a-f]{16}$/.test(spanId)) return null;
  if (!/^[0-9a-f]{2}$/.test(flags)) return null;
  return { traceId, spanId, sampled: (parseInt(flags, 16) & 1) === 1 };
}

export function traceStart(kind, method, parent) {
  if (tracer === null || !traceAllowed(method)) return null;
  const ctx = {
    traceId: parent ? parent.traceId : randomHex(16),
    spanId: randomHex(8),
    parentSpanId: parent ? parent.spanId : "",
    sampled: parent ? parent.sampled : true,
    startMs: Date.now(),
  };
  // An upstream not-sampled decision is honored: the context
  // still propagates (with flags 00) but no span is recorded.
  if (!ctx.sampled) return ctx;
  try {
    tracer.onStart?.(kind, method, ctx.traceId, ctx.spanId, ctx.parentSpanId);
  } catch {
    // observers must never break the call
  }
  return ctx;
}

export function traceEnd(kind, method, ctx, status) {
  if (ctx === null || tracer === null || ctx.sampled === false) return;
  try {
    tracer.onEnd?.(kind, method, ctx.traceId, ctx.spanId, status, Date.now() - ctx.startMs);
  } catch {
    // observers must never break the call
  }
}

// Start a root span context (e.g. for a client workflow grouping
// several outbound calls under one trace). Pair with traceEnd.
// Returns null when tracing is dormant.
export function newTraceContext(kind = "internal", method = "") {
  return traceStart(kind, method, null);
}

// View a span context as a traceparent parent for an outbound call.
export function asTraceParent(ctx) {
  if (!ctx) return null;
  return { traceId: ctx.traceId, spanId: ctx.spanId, sampled: ctx.sampled !== false };
}
GRPC_RUNTIME_EOF
)

(define js-endpoint-body
#<<GRPC_RUNTIME_EOF
// Stream multiplexor: one data channel, many concurrent calls.
// Incoming HEADERS are handed to `dispatcher` (installed by Server);
// everything else is routed to the owning stream's event queue.

import {
  FrameType,
  StatusCode,
  StatusError,
  asUint8Array,
  decodeFrame,
  encodeFrame,
  headersFrame,
  parseHeaders,
  parseStatus,
  statusFrame,
} from "./codec.js";

/** Async queue of stream events with terminal-error semantics. */
export class StreamInput {
  #items = [];
  #waiters = [];
  #error = null;
  #ended = false;

  push(item) {
    if (this.#ended) return;
    const waiter = this.#waiters.shift();
    if (waiter) waiter({ value: item, done: false });
    else this.#items.push(item);
  }

  end() {
    if (this.#ended) return;
    this.#ended = true;
    for (const w of this.#waiters.splice(0)) w({ value: undefined, done: true });
  }

  fail(error) {
    if (this.#ended) return;
    this.#ended = true;
    this.#error = error;
    for (const w of this.#waiters.splice(0)) w({ error, done: true });
  }

  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this.#items.length) {
          return Promise.resolve({ value: this.#items.shift(), done: false });
        }
        if (this.#error) return Promise.reject(this.#error);
        if (this.#ended) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => {
          this.#waiters.push((r) => {
            if (r.error) resolve(Promise.reject(r.error));
            else resolve(r);
          });
        }).then((r) => r);
      },
    };
  }
}

const DRAIN_THRESHOLD = 1 << 20; // 1 MiB of bufferedAmount before pausing

export class Endpoint {
  #dc;
  #streams = new Map();
  #nextId;
  #sendChain = Promise.resolve();
  dispatcher = null; // async (path, headers, input, sink) => void, set by Server

  /**
   * @param dc an RTCDataChannel (browser, werift, node-datachannel) or any
   *   object with send() + message events. Memory pair in loopback.js works.
   * @param parity 'odd' if this peer created the channel, else 'even'.
   */
  constructor(dc, { parity = "odd" } = {}) {
    this.#dc = dc;
    this.#nextId = parity === "odd" ? 1 : 2;
    try {
      dc.binaryType = "arraybuffer";
    } catch {
      /* structural channels may not expose binaryType */
    }
    const onMessage = (event) => {
      const data = event?.data ?? event;
      if (data instanceof Blob) {
        data.arrayBuffer().then((b) => this.#onBytes(new Uint8Array(b)));
      } else {
        try {
          this.#onBytes(asUint8Array(data));
        } catch {
          /* ignore non-binary messages */
        }
      }
    };
    if (typeof dc.addEventListener === "function") {
      dc.addEventListener("message", onMessage);
    } else {
      dc.onmessage = onMessage;
    }
  }

  get dataChannel() {
    return this.#dc;
  }

  /** Allocate a locally-initiated stream. Returns [id, input]. */
  openStream() {
    const id = this.#nextId;
    this.#nextId += 2;
    const input = new StreamInput();
    this.#streams.set(id, input);
    return [id, input];
  }

  closeStream(id) {
    const input = this.#streams.get(id);
    if (input) {
      input.end();
      this.#streams.delete(id);
    }
  }

  /** Abort one stream: RST (CANCELLED) to the peer, and any
   * local reader wakes with that CANCELLED status. */
  cancelStream(id) {
    const status = new StatusError(StatusCode.CANCELLED, "call cancelled");
    const input = this.#streams.get(id);
    if (input) {
      input.push({ kind: "rst", status, trailers: {} });
      this.#streams.delete(id);
    }
    this.sendFrame(statusFrame(FrameType.RST, id, status)).catch(() => {});
  }

  async sendFrame(frameBytes) {
    // Serialize sends so HEADERS never overtakes a previous frame on the
    // wire, and pause while the SCTP send buffer is above the threshold.
    const run = async () => {
      await this.#waitForDrain();
      if (this.#dc.readyState && this.#dc.readyState !== "open") {
        throw StatusError.unavailable("data channel is not open");
      }
      this.#dc.send(frameBytes);
    };
    this.#sendChain = this.#sendChain.then(run, run);
    return this.#sendChain;
  }

  async #waitForDrain() {
    const dc = this.#dc;
    if (typeof dc.bufferedAmount !== "number" || dc.bufferedAmount <= DRAIN_THRESHOLD) return;
    await new Promise((resolve) => {
      if (typeof dc.addEventListener === "function") {
        try {
          dc.bufferedAmountLowThreshold = DRAIN_THRESHOLD / 2;
        } catch {
          /* optional */
        }
        const done = () => {
          dc.removeEventListener?.("bufferedamountlow", done);
          resolve();
        };
        dc.addEventListener("bufferedamountlow", done);
        setTimeout(done, 50); // fallback poll for structural channels
      } else {
        setTimeout(resolve, 10);
      }
    });
    if (typeof dc.bufferedAmount === "number" && dc.bufferedAmount > DRAIN_THRESHOLD) {
      return this.#waitForDrain();
    }
  }

  #onBytes(bytes) {
    let frame;
    try {
      frame = decodeFrame(bytes);
    } catch {
      return; // malformed frame: drop, keep the channel up
    }
    const { type, streamId, payload } = frame;
    @@FRAME_DISPATCH@@
  }

  #push(streamId, event) {
    this.#streams.get(streamId)?.push(event);
  }

  #terminal(streamId, payload, kind) {
    const status = parseStatus(payload);
    this.#streams.get(streamId)?.push({ kind, status, trailers: status.trailers ?? {} });
    this.#streams.delete(streamId);
  }

  async #onHeaders(streamId, payload) {
    let headers;
    try {
      headers = parseHeaders(payload);
    } catch (e) {
      this.sendFrame(statusFrame(FrameType.RST, streamId, e)).catch(() => {});
      return;
    }
    if (headers.path === null) {
      // Server initial metadata for one of our outbound streams.
      this.#streams.get(streamId)?.push({ kind: "headers", headers });
      return;
    }
    if (this.#streams.has(streamId)) {
      this.sendFrame(
        statusFrame(
          FrameType.RST,
          streamId,
          StatusError.internal("HEADERS for stream already in use"),
        ),
      ).catch(() => {});
      return;
    }
    if (!this.dispatcher) {
      this.sendFrame(
        statusFrame(
          FrameType.TRAILERS,
          streamId,
          StatusError.unimplemented(`unknown method ${headers.path}`),
        ),
      ).catch(() => {});
      return;
    }
    const input = new StreamInput();
    this.#streams.set(streamId, input);
    const sink = {
      // A stream dropped from the map was RST by the peer (or
      // the channel went away): fail the send so a producing
      // handler stops instead of streaming into the void.
      sendData: (payload) => {
        if (!this.#streams.has(streamId)) {
          throw new StatusError(StatusCode.CANCELLED, "call cancelled");
        }
        return this.sendFrame(encodeFrame(FrameType.DATA, streamId, payload));
      },
      sendHeaders: (metadata = {}) => {
        if (!this.#streams.has(streamId)) {
          throw new StatusError(StatusCode.CANCELLED, "call cancelled");
        }
        return this.sendFrame(headersFrame(streamId, null, metadata));
      },
      sendTrailers: (status, trailers) =>
        this.sendFrame(statusFrame(FrameType.TRAILERS, streamId, status, trailers)),
    };
    try {
      // No eager HEADERS: the dispatcher sends initial metadata
      // via sink.sendHeaders (Server does it lazily before the
      // first DATA). A dispatcher may return {trailers} to have
      // them ride the OK status frame.
      const extra = await this.dispatcher(headers.path, headers, input, sink);
      await sink.sendTrailers(StatusError.ok(), extra?.trailers);
    } catch (e) {
      const status =
        e instanceof StatusError ? e : StatusError.internal(e?.message ?? String(e));
      await sink.sendTrailers(status).catch(() => {});
    } finally {
      this.#streams.delete(streamId);
    }
  }

  /** Fail every live stream (channel teardown). */
  closeAll() {
    for (const input of this.#streams.values()) {
      input.fail(StatusError.unavailable("data channel closed"));
    }
    this.#streams.clear();
  }
}

export { StatusCode };
GRPC_RUNTIME_EOF
)

(define js-channel-body
#<<GRPC_RUNTIME_EOF
// Client side: opens streams on one endpoint, all four gRPC shapes.
// Message types are classes with static encode(msg)/decode(bytes).

import {
  FrameType,
  StatusError,
  StatusName,
  encodeFrame,
  encodeTimeout,
  formatTraceparent,
  getTracer,
  headersFrame,
  asTraceParent,
  parseTraceparent,
  statusFrame,
  traceEnd,
  traceStart,
} from "./codec.js";
import { Endpoint } from "./endpoint.js";

// AsyncIterable wrapper whose iterator keeps ONE read in
// flight at a time (no read-ahead). for-await on an async
// generator runs next() with no pipelining, so by the time a
// consumer breaks, the generator may already be parked in a
// read for an event nobody will consume; unwinding then has
// to wait for that read to settle, which for a quiet
// server-streaming call may be never. This wrapper hands the
// consumer an iterator over a one-slot queue instead: the
// inner generator is pumped into the queue only as fast as
// events arrive, .return() releases the consumer immediately,
// and the abandoned pump is dropped (its pending read is
// released by the cancel: the RST makes the server end the
// call, which settles the read with trailers).
function responsesIterable(inner, cancel) {
  return {
    [Symbol.asyncIterator]() {
      const iterator = inner[Symbol.asyncIterator]();
      const queue = [];
      let waiter = null;
      let done = false;
      let failure = null;
      const notify = () => {
        if (waiter) {
          const wake = waiter;
          waiter = null;
          wake();
        }
      };
      (async () => {
        try {
          for (;;) {
            const step = await iterator.next();
            if (step.done) break;
            queue.push(step.value);
            notify();
          }
        } catch (e) {
          failure = e;
        } finally {
          done = true;
          notify();
        }
      })();
      return {
        [Symbol.asyncIterator]() {
          return this;
        },
        async next() {
          for (;;) {
            if (queue.length) return { value: queue.shift(), done: false };
            if (failure) throw failure;
            if (done) return { value: undefined, done: true };
            await new Promise((resolve) => { waiter = resolve; });
          }
        },
        async return(value) {
          done = true;
          cancel();
          notify();
          return { value, done: true };
        },
      };
    },
  };
}

export class Channel {
  #endpoint;
  #traces = new Map();
  #traceContext = null;
  #metadataProvider = null;

  // A Channel view sharing this endpoint whose outbound spans are
  // parented to traceContext (a server span context from
  // ctx.traceContext, or a root from newTraceContext). Explicit
  // call metadata still wins. This is the browser-safe propagation
  // path: no ambient async context is assumed.
  withTraceContext(traceContext) {
    const ch = new Channel(this.#endpoint);
    ch.#traceContext = traceContext ?? null;
    ch.#metadataProvider = this.#metadataProvider;
    return ch;
  }

  // A Channel view sharing this endpoint that merges metadata
  // from `provider` (a map, or a function returning a map or a
  // promise of one) into every call. Explicit per-call metadata
  // still wins. Used by rendezvousChannel to attach the
  // authorization bearer token per call.
  withMetadata(provider) {
    const ch = new Channel(this.#endpoint);
    ch.#traceContext = this.#traceContext;
    ch.#metadataProvider = provider ?? null;
    return ch;
  }

  /** Accepts an Endpoint or a raw RTCDataChannel-like object. */
  constructor(dcOrEndpoint, options) {
    this.#endpoint =
      dcOrEndpoint instanceof Endpoint ? dcOrEndpoint : new Endpoint(dcOrEndpoint, options);
  }

  get endpoint() {
    return this.#endpoint;
  }

  async #open(path, metadata, timeout, signal = null) {
    if (this.#metadataProvider !== null) {
      const provided =
        typeof this.#metadataProvider === "function"
          ? await this.#metadataProvider()
          : this.#metadataProvider;
      if (provided) metadata = { ...provided, ...metadata };
    }
    let deadline = null;
    if (timeout !== undefined && timeout !== null) {
      deadline = Date.now() + timeout;
      metadata = { ...metadata, "grpc-timeout": encodeTimeout(timeout) };
    }
    let traceCtx = null;
    if (getTracer() !== null) {
      traceCtx = traceStart(
        "client",
        path,
        parseTraceparent(metadata?.traceparent) ?? asTraceParent(this.#traceContext),
      );
      if (traceCtx !== null) {
        metadata = {
          ...metadata,
          traceparent: formatTraceparent(traceCtx.traceId, traceCtx.spanId, traceCtx.sampled),
        };
      }
    }
    const [id, input] = this.#endpoint.openStream();
    if (traceCtx !== null) this.#traces.set(id, { ctx: traceCtx, path });
    if (signal) {
      // Per-call cancellation: an aborted AbortSignal aborts
      // the stream (RST CANCELLED; pending reads fail with
      // CANCELLED). Stream ids are never reused, so a late
      // abort after completion is a harmless no-op.
      const onAbort = () => this.#endpoint.cancelStream(id);
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
    }
    try {
      await this.#endpoint.sendFrame(headersFrame(id, path, metadata));
    } catch (e) {
      this.#endTrace(id, "UNAVAILABLE");
      this.#endpoint.closeStream(id);
      throw e;
    }
    return [id, input, deadline];
  }

  #endTrace(id, status) {
    const entry = this.#traces.get(id);
    if (entry) {
      this.#traces.delete(id);
      traceEnd("client", entry.path, entry.ctx, status);
    }
  }

  // Next event from input's iterator, enforcing the call deadline:
  // on expiry the stream is aborted (RST) and DEADLINE_EXCEEDED
  // (code 4) is thrown.
  async #next(id, iterator, deadline) {
    if (deadline === null) return iterator.next();
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      await this.cancel(id).catch(() => {});
      throw new StatusError(4, "deadline exceeded");
    }
    let timer;
    try {
      return await Promise.race([
        iterator.next(),
        new Promise((_, reject) => {
          timer = setTimeout(
            () => reject(new StatusError(4, "deadline exceeded")),
            remaining,
          );
        }),
      ]);
    } catch (e) {
      if (e instanceof StatusError && e.code === 4) {
        await this.cancel(id).catch(() => {});
      }
      throw e;
    } finally {
      clearTimeout(timer);
    }
  }

  async #sendMessage(id, ReqType, request) {
    await this.#endpoint.sendFrame(encodeFrame(FrameType.DATA, id, ReqType.encode(request)));
  }

  // hooks: optional {onHeaders, onTrailers} from call options,
  // invoked with the response initial/trailing metadata ({} when
  // the peer sent none). Trailers also ride the terminal
  // StatusError as .trailers, success or failure.
  async #collectOne(id, input, RespType, deadline = null, hooks = {}) {
    const iterator = input[Symbol.asyncIterator]();
    try {
      let response = null;
      for (;;) {
        const step = await this.#next(id, iterator, deadline);
        if (step.done) break;
        const event = step.value;
        if (event.kind === "headers") {
          hooks.onHeaders?.(event.headers?.metadata ?? {});
        } else if (event.kind === "data") {
          if (response !== null) {
            throw StatusError.internal("unary call received more than one response");
          }
          response = RespType.decode(event.payload);
        } else if (event.kind === "trailers") {
          hooks.onTrailers?.(event.trailers ?? {});
          this.#endTrace(id, StatusName[event.status.code] ?? `CODE_${event.status.code}`);
          if (event.status.code !== 0) throw event.status;
          if (response === null) throw StatusError.internal("call closed with no response");
          return response;
        } else if (event.kind === "rst") {
          this.#endTrace(id, StatusName[event.status.code] ?? `CODE_${event.status.code}`);
          throw event.status;
        }
      }
      throw StatusError.unavailable("data channel closed");
    } finally {
      this.#endTrace(id, "UNAVAILABLE");
      this.#endpoint.closeStream(id);
    }
  }

  async *#responses(id, input, RespType, deadline = null, hooks = {}) {
    const iterator = input[Symbol.asyncIterator]();
    let completed = false;
    // A caller-owned ReadHandle makes `.return()` asynchronous
    // with an internal queue, so wrapping the iterator handed
    // to the consumer in a pausable shim is what lets a break
    // actually cancel the call. The shim carries no buffering:
    // events are pulled one at a time straight from `iterator`.
    const consumer = {
      [Symbol.asyncIterator]() {
        return this;
      },
      next: () => this.#next(id, iterator, deadline),
      return: async () => {
        completed = false;
        this.#endpoint.cancelStream(id);
        return { value: undefined, done: true };
      },
    };
    // The in-flight read and its abort: StreamInput resolves a
    // pending read only on stream events, and the endpoint
    // deliberately never fails locally-initiated streams, so
    // on early exit (.return()) nothing else would release a
    // read the race below abandoned. The abort fails that read
    // with CANCELLED, which propagates out of the abandoned
    // read without disturbing the yielded-event flow.
    let abortReading = null;
    try {
      for (;;) {
        const step = await new Promise((resolve, reject) => {
          abortReading = () =>
            reject(new StatusError(StatusCode.CANCELLED, "call cancelled"));
          consumer.next().then(
            (s) => { abortReading = null; resolve(s); },
            (e) => { abortReading = null; reject(e); },
          );
        });
        if (step.done) break;
        const event = step.value;
        if (event.kind === "headers") {
          hooks.onHeaders?.(event.headers?.metadata ?? {});
        } else if (event.kind === "data") {
          yield RespType.decode(event.payload);
        } else if (event.kind === "trailers") {
          completed = true;
          hooks.onTrailers?.(event.trailers ?? {});
          this.#endTrace(id, StatusName[event.status.code] ?? `CODE_${event.status.code}`);
          if (event.status.code !== 0) throw event.status;
          return;
        } else if (event.kind === "rst") {
          completed = true;
          this.#endTrace(id, StatusName[event.status.code] ?? `CODE_${event.status.code}`);
          throw event.status;
        }
      }
      throw StatusError.unavailable("data channel closed");
    } finally {
      this.#endTrace(id, "UNAVAILABLE");
      // Consumer stopped early (broke out of iteration): cancel
      // so the server stops producing instead of streaming into
      // the void. A completed call just closes locally. This
      // finally runs while the abandoned read above is still
      // pending; abort it so its rejection cannot surface as an
      // unhandled rejection after this generator completes.
      if (abortReading) {
        const abort = abortReading;
        abortReading = null;
        abort();
      }
      if (completed) this.#endpoint.closeStream(id);
      else this.#endpoint.cancelStream(id);
    }
  }

  async #pump(id, requests, ReqType) {
    try {
      for await (const request of requests) {
        await this.#sendMessage(id, ReqType, request);
      }
      await this.#endpoint.sendFrame(encodeFrame(FrameType.HALF_CLOSE, id));
    } catch (e) {
      const status = e instanceof StatusError ? e : StatusError.internal(e?.message ?? String(e));
      await this.#endpoint
        .sendFrame(statusFrame(FrameType.RST, id, status))
        .catch(() => {});
    }
  }

  /** Unary: one request, one response. */
  async unary(path, request, ReqType, RespType, { metadata = {}, timeout, onHeaders, onTrailers, signal } = {}) {
    const [id, input, deadline] = await this.#open(path, metadata, timeout, signal);
    await this.#sendMessage(id, ReqType, request);
    await this.#endpoint.sendFrame(encodeFrame(FrameType.HALF_CLOSE, id));
    return this.#collectOne(id, input, RespType, deadline, { onHeaders, onTrailers });
  }

  /** Server-streaming: one request, async iterable of responses. */
  serverStream(path, request, ReqType, RespType, { metadata = {}, timeout, onHeaders, onTrailers, signal } = {}) {
    return (async () => {
      const [id, input, deadline] = await this.#open(path, metadata, timeout, signal);
      await this.#sendMessage(id, ReqType, request);
      await this.#endpoint.sendFrame(encodeFrame(FrameType.HALF_CLOSE, id));
      return responsesIterable(this.#responses(id, input, RespType, deadline, { onHeaders, onTrailers }), () => this.#endpoint.cancelStream(id));
    })();
  }

  /** Client-streaming: async iterable of requests, one response. */
  async clientStream(path, requests, ReqType, RespType, { metadata = {}, timeout, onHeaders, onTrailers, signal } = {}) {
    const [id, input, deadline] = await this.#open(path, metadata, timeout, signal);
    const pump = this.#pump(id, requests, ReqType);
    try {
      return await this.#collectOne(id, input, RespType, deadline, { onHeaders, onTrailers });
    } finally {
      pump.catch(() => {});
    }
  }

  /** Bidirectional: async iterable of requests and of responses. */
  bidi(path, requests, ReqType, RespType, { metadata = {}, timeout, onHeaders, onTrailers, signal } = {}) {
    return (async () => {
      const [id, input, deadline] = await this.#open(path, metadata, timeout, signal);
      const pump = this.#pump(id, requests, ReqType);
      pump.catch(() => {});
      return responsesIterable(this.#responses(id, input, RespType, deadline, { onHeaders, onTrailers }), () => this.#endpoint.cancelStream(id));
    })();
  }

  /** Abort a call: sends RST CANCELLED. */
  /** Abort a call: RST CANCELLED to the peer, CANCELLED locally. */
  async cancel(streamId) {
    this.#endpoint.cancelStream(streamId);
  }
}
GRPC_RUNTIME_EOF
)

(define js-server-body
#<<GRPC_RUNTIME_EOF
// Server side: registers generated service definitions (createXService)
// on an endpoint and dispatches HEADERS by path.

import {
  StatusCode,
  StatusError,
  StatusName,
  parseTimeout,
  parseTraceparent,
  traceEnd,
  traceStart,
} from "./codec.js";
import { Endpoint } from "./endpoint.js";

async function* typedRequests(input, ReqType) {
  for await (const event of input) {
    if (event.kind === "data") {
      yield ReqType.decode(event.payload);
    } else if (event.kind === "half-close") {
      return;
    } else if (event.kind === "trailers" || event.kind === "rst") {
      throw event.status;
    }
  }
}

async function firstRequest(requests) {
  const iterator = requests[Symbol.asyncIterator]();
  const first = await iterator.next();
  if (first.done) {
    throw StatusError.invalidArgument("missing request message");
  }
  return first.value;
}

export class Server {
  #methods = new Map();
  #authVerifier = null;
  #authScopes = {};
  #interceptors = [];

  addService(definition) {
    for (const [name, method] of Object.entries(definition.methods)) {
      if (typeof method.handler !== "function") {
        throw new Error(`grpc-dc: missing handler for ${definition.name}.${name}`);
      }
      this.#methods.set(method.path, { ...method, service: definition.name, method: name });
    }
    return this;
  }

  /**
   * Require rendezvous bearer auth on every call: `verifier`
   * is an async (token) => claims function that throws on a
   * bad, missing or expired token; `scopes` maps a method path
   * to the scopes it requires (no entry = any authenticated
   * caller). Verified claims land on ctx.claims. Installed by
   * serveRendezvous when options.auth is set; rendezvous-only
   * by design (no protoc plugin option).
   */
  /** Remove every method of `name` (runtime unregistration). */
  removeService(name) {
    const prefix = `/${name}/`;
    for (const path of [...this.#methods.keys()]) {
      if (path.startsWith(prefix)) this.#methods.delete(path);
    }
    return this;
  }

  /** Names of registered services, sorted (discovery source). */
  registeredServices() {
    const names = new Set();
    for (const { service } of this.#methods.values()) names.add(service);
    return [...names].sort();
  }

  /**
   * Install a server interceptor: `fn({path, metadata})` runs
   * in install order before dispatch (after rendezvous auth
   * when set). Throwing a StatusError ends the call with that
   * status and the handler never runs. Return a claims object
   * to expose it as ctx.claims when no auth claims are set.
   */
  addInterceptor(fn) {
    this.#interceptors.push(fn);
    return this;
  }

  requireRendezvousAuth(verifier, scopes = {}) {
    this.#authVerifier = verifier;
    this.#authScopes = scopes ?? {};
    return this;
  }

  /** Attach to an endpoint (or raw channel, wrapped with even parity). */
  serve(dcOrEndpoint, options) {
    const endpoint =
      dcOrEndpoint instanceof Endpoint
        ? dcOrEndpoint
        : new Endpoint(dcOrEndpoint, { parity: "even", ...options });
    endpoint.dispatcher = (path, headers, input, sink) =>
      this.#dispatch(path, headers, input, sink);
    return endpoint;
  }

  async #dispatch(path, headers, input, sink) {
    const method = this.#methods.get(path);
    if (!method) {
      throw StatusError.unimplemented(`unknown method ${path}`);
    }
    const metadata = headers.metadata ?? {};
    let claims = null;
    if (this.#authVerifier !== null) {
      const header = metadata.authorization ?? "";
      const match = /^Bearer (.+)$/.exec(header);
      if (!match) {
        throw new StatusError(StatusCode.UNAUTHENTICATED, "missing bearer token");
      }
      try {
        claims = await this.#authVerifier(match[1]);
      } catch (e) {
        throw new StatusError(
          StatusCode.UNAUTHENTICATED,
          e instanceof Error ? e.message : "invalid bearer token",
        );
      }
      const required = this.#authScopes[path] ?? [];
      const granted = new Set(claims?.scopes ?? []);
      for (const scope of required) {
        if (!granted.has(scope)) {
          throw new StatusError(
            StatusCode.PERMISSION_DENIED,
            `missing required scope ${scope}`,
          );
        }
      }
    }
    for (const interceptor of this.#interceptors) {
      const extra = await interceptor({ path, metadata });
      if (claims === null && extra !== null && typeof extra === "object") {
        claims = extra;
      }
    }
    const timeoutMs = parseTimeout(metadata["grpc-timeout"]);
    const deadline = timeoutMs === null ? null : Date.now() + timeoutMs;
    // Initial/trailing metadata the handler accumulates via
    // ctx.setHeaders/ctx.setTrailers. Initial metadata flushes
    // lazily, right before the first response DATA (or at the
    // end of a call that produced none); trailers ride the
    // terminal status frame.
    const responseHeaders = {};
    const responseTrailers = {};
    let headersSent = false;
    const flushHeaders = async () => {
      if (!headersSent) {
        headersSent = true;
        await sink.sendHeaders(responseHeaders);
      }
    };
    const callSink = {
      sendHeaders: flushHeaders,
      sendData: async (payload) => {
        await flushHeaders();
        await sink.sendData(payload);
      },
      sendTrailers: sink.sendTrailers,
    };
    const ctx = {
      path,
      metadata,
      claims,
      service: method.service,
      method: method.method,
      deadline,
      timeRemaining: () => (deadline === null ? null : deadline - Date.now()),
      setHeaders: (md) => Object.assign(responseHeaders, md),
      setTrailers: (md) => Object.assign(responseTrailers, md),
    };
    const traceCtx = traceStart("server", path, parseTraceparent(metadata.traceparent));
    ctx.traceContext = traceCtx;
    let traceStatus = "OK";
    try {
      await this.#dispatchTraced(path, method, ctx, input, callSink);
      await flushHeaders();
      return { trailers: responseTrailers };
    } catch (e) {
      traceStatus =
        e instanceof StatusError
          ? (StatusName[e.code] ?? `CODE_${e.code}`)
          : "INTERNAL";
      // Trailers set before the failure still ride the status
      // frame (statusFrame reads status.trailers).
      if (e instanceof StatusError) e.trailers = { ...responseTrailers, ...(e.trailers ?? {}) };
      throw e;
    } finally {
      traceEnd("server", path, traceCtx, traceStatus);
    }
  }

  async #dispatchTraced(path, method, ctx, input, sink) {
    const requests = typedRequests(input, method.requestType);
    const encode = (resp) => method.responseType.encode(resp);
    switch (method.kind) {
      case "unary": {
        const req = await firstRequest(requests);
        const resp = await method.handler(req, ctx);
        await sink.sendData(encode(resp));
        return;
      }
      case "server-streaming": {
        const req = await firstRequest(requests);
        const out = await method.handler(req, ctx);
        for await (const resp of out) {
          await sink.sendData(encode(resp));
        }
        return;
      }
      case "client-streaming": {
        const resp = await method.handler(requests, ctx);
        await sink.sendData(encode(resp));
        return;
      }
      case "bidi": {
        const out = await method.handler(requests, ctx);
        for await (const resp of out) {
          await sink.sendData(encode(resp));
        }
        return;
      }
      default:
        throw StatusError.unimplemented(`unknown method kind ${method.kind}`);
    }
  }
}
GRPC_RUNTIME_EOF
)

(define js-chunking-body
#<<GRPC_RUNTIME_EOF
// DataChannel message chunking: browsers reject (and peers
// drop) single RTCDataChannel messages above the negotiated
// max-message-size (262144 in Chromium), so a grpc-dc frame
// larger than that could never cross a browser. This shim
// sits below the Endpoint, on the DC message layer: outgoing
// messages over MAX_DC_CHUNK_PAYLOAD are split into chunk
// messages with a 2-byte header [magic, flags]; incoming
// chunk messages are reassembled before the Endpoint sees
// them. Messages at or under the limit pass through byte-
// identical, and the magic byte (0xF0) is an unknown grpc-dc
// frame type, so a peer without the shim ignores chunks
// instead of misdecoding them (the documented forward-compat
// rule) — chunking is safe to enable on one side of a link
// whose other side only ever receives small messages, and
// required on both sides for large ones.
//
// The native WebRTC stacks (webrtc/rust, webrtc/go,
// webrtc/js) implement the same format behind an opt-in flag.

export const DC_CHUNK_MAGIC = 0xf0;
export const DC_CHUNK_FINAL = 0x01;
export const MAX_DC_CHUNK_PAYLOAD = 65536;

/** Split one DC message into wire messages (raw if small). */
export function splitDcMessage(bytes, maxPayload = MAX_DC_CHUNK_PAYLOAD) {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (data.length <= maxPayload) return [data];
  const out = [];
  for (let off = 0; off < data.length; off += maxPayload) {
    const last = off + maxPayload >= data.length;
    const chunk = new Uint8Array(2 + Math.min(maxPayload, data.length - off));
    chunk[0] = DC_CHUNK_MAGIC;
    chunk[1] = last ? DC_CHUNK_FINAL : 0;
    chunk.set(data.subarray(off, off + Math.min(maxPayload, data.length - off)), 2);
    out.push(chunk);
  }
  return out;
}

/** Stateful reassembler: push one wire message, get the
 * complete logical message or null while chunks accumulate.
 * Non-chunk messages pass through untouched. */
export class DcChunkReassembler {
  #parts = null;

  push(bytes) {
    const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (this.#parts === null && (data.length < 2 || data[0] !== DC_CHUNK_MAGIC)) {
      return data;
    }
    if (data.length < 2 || data[0] !== DC_CHUNK_MAGIC) {
      // Raw message interleaved mid-reassembly (should not
      // happen on an ordered channel): drop the partial.
      this.#parts = null;
      return data;
    }
    if (this.#parts === null) this.#parts = [];
    this.#parts.push(data.subarray(2));
    if ((data[1] & DC_CHUNK_FINAL) === 0) return null;
    const total = this.#parts.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(total);
    let off = 0;
    for (const part of this.#parts) {
      out.set(part, off);
      off += part.length;
    }
    this.#parts = null;
    return out;
  }
}

/** Wrap a DataChannel-shaped object (send + message events)
 * with chunk-split sends and reassembling receives. The
 * Endpoint-facing interface is preserved. */
export function chunkedDataChannel(dc, { maxPayload = MAX_DC_CHUNK_PAYLOAD } = {}) {
  const reassembler = new DcChunkReassembler();
  const listeners = new Map();
  const emit = (name, event) => {
    for (const fn of listeners.get(name) ?? []) fn(event);
  };
  const onRawMessage = (event) => {
    let data = event?.data ?? event;
    const done = (bytes) => {
      const whole = reassembler.push(bytes);
      if (whole !== null) emit("message", { data: whole });
    };
    if (typeof Blob !== "undefined" && data instanceof Blob) {
      data.arrayBuffer().then((b) => done(new Uint8Array(b)));
    } else if (data instanceof ArrayBuffer) {
      done(new Uint8Array(data));
    } else if (ArrayBuffer.isView(data)) {
      done(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
    } else {
      emit("message", event);
    }
  };
  if (typeof dc.addEventListener === "function") dc.addEventListener("message", onRawMessage);
  else dc.onmessage = onRawMessage;
  for (const name of ["open", "close", "error", "bufferedamountlow"]) {
    if (typeof dc.addEventListener === "function") {
      dc.addEventListener(name, (e) => emit(name, e));
    }
  }
  return {
    get readyState() {
      return dc.readyState;
    },
    get bufferedAmount() {
      return dc.bufferedAmount ?? 0;
    },
    set bufferedAmountLowThreshold(v) {
      try {
        dc.bufferedAmountLowThreshold = v;
      } catch {
        /* structural channels may not expose it */
      }
    },
    set binaryType(v) {
      try {
        dc.binaryType = v;
      } catch {
        /* ignore */
      }
    },
    send(bytes) {
      for (const chunk of splitDcMessage(bytes, maxPayload)) dc.send(chunk);
    },
    addEventListener(name, fn) {
      if (!listeners.has(name)) listeners.set(name, []);
      listeners.get(name).push(fn);
    },
    removeEventListener(name, fn) {
      const list = listeners.get(name) ?? [];
      const i = list.indexOf(fn);
      if (i >= 0) list.splice(i, 1);
    },
    close() {
      dc.close?.();
    },
  };
}
GRPC_RUNTIME_EOF
)

(define js-loopback-body
#<<GRPC_RUNTIME_EOF
// In-memory RTCDataChannel pair for Node tests and demos: message
// boundaries preserved, ordered, reliable — the same contract a real
// RTCDataChannel offers. Delivery is a microtask, like a fast network.

class MemoryDataChannel {
  #listeners = new Map();

  constructor(label) {
    this.label = label;
    this.readyState = "open";
    this.bufferedAmount = 0;
    this.binaryType = "arraybuffer";
    this.peer = null;
  }

  addEventListener(type, fn) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, []);
    this.#listeners.get(type).push(fn);
  }

  removeEventListener(type, fn) {
    const list = this.#listeners.get(type) ?? [];
    this.#listeners.set(type, list.filter((f) => f !== fn));
  }

  #emit(type, event) {
    for (const fn of [...(this.#listeners.get(type) ?? [])]) fn(event);
    const handler = this[`on${type}`];
    if (typeof handler === "function") handler(event);
  }

  send(data) {
    if (this.readyState !== "open") throw new Error("data channel is not open");
    const copy = data instanceof Uint8Array ? data.slice() : data;
    const peer = this.peer;
    queueMicrotask(() => {
      if (peer.readyState === "open") peer.#emit("message", { data: copy });
    });
  }

  close() {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    this.#emit("close", {});
    if (this.peer.readyState !== "closed") {
      this.peer.readyState = "closed";
      this.peer.#emit("close", {});
    }
  }
}

export function memoryDataChannelPair() {
  const a = new MemoryDataChannel("a");
  const b = new MemoryDataChannel("b");
  a.peer = b;
  b.peer = a;
  return [a, b];
}
GRPC_RUNTIME_EOF
)

(define js-wasm-bridge-body
#<<GRPC_RUNTIME_EOF
// WASM bridge: the generic byte-level surface that generated WASM
// client facades (Go/Rust/...) call into. The JS runtime owns the
// wire; the facade owns the types. Payloads cross the boundary as
// Uint8Array protobuf bytes, so no object mapping is needed.
//
//   unary(path, payload, options?) -> Promise<Uint8Array>
//   serverStream(path, payload, onMessage, options?) -> Promise<void>
//   clientStream(path, payloads, options?) -> Promise<Uint8Array>
//   bidi(path, payloads, onMessage, options?) -> Promise<void>
//
// options may carry {metadata, timeout} (forwarded to the call)
// and, for streaming calls, {cancelAfter: n} to abort the stream
// after n responses. onMessage receives one Uint8Array per
// response; the promise resolves on OK trailers and rejects
// with StatusError otherwise.

import { Channel } from "./channel.js";
import { Server } from "./server.js";
import { StatusError } from "./codec.js";

const identity = { encode: (bytes) => bytes, decode: (bytes) => bytes };

async function* fromList(items) {
  yield* items;
}

export function createGrpcDcBridge(dcOrChannel) {
  const channel = dcOrChannel instanceof Channel ? dcOrChannel : new Channel(dcOrChannel);
  const callOptions = (options) => ({
    metadata: options?.metadata ?? {},
    timeout: options?.timeout,
  });
  return {
    async unary(path, payload, options) {
      return channel.unary(path, payload, identity, identity, callOptions(options));
    },
    async serverStream(path, payload, onMessage, options) {
      const responses = await channel.serverStream(path, payload, identity, identity, callOptions(options));
      let seen = 0;
      for await (const resp of responses) {
        onMessage(resp);
        seen++;
        // cancelAfter: the caller aborts the stream after this
        // many responses (breaking the iteration tears the call
        // down); the promise then resolves normally.
        if (options?.cancelAfter && seen >= options.cancelAfter) break;
      }
    },
    async clientStream(path, payloads, options) {
      return channel.clientStream(path, fromList(payloads), identity, identity, callOptions(options));
    },
    async bidi(path, payloads, onMessage, options) {
      const responses = await channel.bidi(path, fromList(payloads), identity, identity, callOptions(options));
      let seen = 0;
      for await (const resp of responses) {
        onMessage(resp);
        seen++;
        if (options?.cancelAfter && seen >= options.cancelAfter) break;
      }
    },
  };
}

// Server bridge: the mirror image for generated WASM server
// facades. The JS runtime still owns the wire (a real Server
// on the channel); the facade registers typed handlers per
// path. Handlers receive protobuf bytes plus metadata as a
// flattened [key, value, ...] string array and respond in
// bytes; streaming handlers push responses through onMessage
// and settle their promise at the end. Handler failures cross
// as {code, message} objects and become StatusError here.
// Facade client-streaming/bidi calls deliver all requests up
// front, so clientStream/bidi handlers receive the full list
// (same shape as the client bridge's payloads).
function toStatusError(err) {
  if (err instanceof StatusError) return err;
  const code = err && typeof err.code === "number" ? err.code : 13;
  const message = err && err.message ? String(err.message) : String(err);
  return new StatusError(code, message);
}

function metadataPairs(metadata) {
  return Object.entries(metadata ?? {}).flat();
}

async function* collectResponses(invoke) {
  const queue = [];
  let notify = null;
  let settled = false;
  let failure = null;
  const wake = () => {
    if (notify) {
      const resolve = notify;
      notify = null;
      resolve();
    }
  };
  invoke((bytes) => {
    queue.push(bytes);
    wake();
  }).then(
    () => {
      settled = true;
      wake();
    },
    (err) => {
      failure = err;
      settled = true;
      wake();
    }
  );
  for (;;) {
    while (queue.length > 0) yield queue.shift();
    if (settled) break;
    await new Promise((resolve) => {
      notify = resolve;
    });
  }
  if (failure) throw toStatusError(failure);
}

/** Pull-based view of a request stream for incremental handlers. */
function requestSource(requests) {
  const iterator = requests[Symbol.asyncIterator]();
  return {
    next: async () => {
      const result = await iterator.next();
      return result.done ? null : result.value;
    },
  };
}

export function createGrpcDcServerBridge(dcOrChannel) {
  const channel = dcOrChannel instanceof Channel ? dcOrChannel : new Channel(dcOrChannel);
  const server = new Server();
  const methods = {};
  let started = false;
  const register = (path, method) => {
    methods[path] = method;
  };
  return {
    registerUnary(path, handler) {
      register(path, {
        path,
        kind: "unary",
        requestType: identity,
        responseType: identity,
        handler: async (req, ctx) => {
          try {
            return await handler(req, metadataPairs(ctx.metadata));
          } catch (err) {
            throw toStatusError(err);
          }
        },
      });
    },
    registerServerStream(path, handler) {
      register(path, {
        path,
        kind: "server-streaming",
        requestType: identity,
        responseType: identity,
        handler: (req, ctx) =>
          collectResponses((onMessage) => handler(req, metadataPairs(ctx.metadata), onMessage)),
      });
    },
    registerClientStream(path, handler) {
      register(path, {
        path,
        kind: "client-streaming",
        requestType: identity,
        responseType: identity,
        handler: async (requests, ctx) => {
          const payloads = [];
          for await (const req of requests) payloads.push(req);
          try {
            return await handler(payloads, metadataPairs(ctx.metadata));
          } catch (err) {
            throw toStatusError(err);
          }
        },
      });
    },
    registerBidi(path, handler) {
      register(path, {
        path,
        kind: "bidi",
        requestType: identity,
        responseType: identity,
        handler: async (requests, ctx) => {
          const payloads = [];
          for await (const req of requests) payloads.push(req);
          return collectResponses((onMessage) =>
            handler(payloads, metadataPairs(ctx.metadata), onMessage)
          );
        },
      });
    },
    // Incremental variants: the handler pulls requests one at a
    // time from source.next() (null at end of stream) instead of
    // receiving every payload up front, so a bidi handler can
    // answer each request before the next one is sent.
    registerClientStreamInc(path, handler) {
      register(path, {
        path,
        kind: "client-streaming",
        requestType: identity,
        responseType: identity,
        handler: async (requests, ctx) => {
          try {
            return await handler(requestSource(requests), metadataPairs(ctx.metadata));
          } catch (err) {
            throw toStatusError(err);
          }
        },
      });
    },
    registerBidiInc(path, handler) {
      register(path, {
        path,
        kind: "bidi",
        requestType: identity,
        responseType: identity,
        handler: (requests, ctx) =>
          collectResponses((onMessage) =>
            handler(requestSource(requests), metadataPairs(ctx.metadata), onMessage)
          ),
      });
    },
    start(serviceName) {
      if (started) return;
      started = true;
      server.addService({ name: serviceName ?? "grpc-dc-bridge", methods });
      // Serve on the channel's endpoint (a raw DataChannel is
      // wrapped by Server itself; a Channel must not be).
      server.serve(channel instanceof Channel ? channel.endpoint : channel);
    },
  };
}
GRPC_RUNTIME_EOF
)

;; Frame dispatch: switch arms are expanded from spec.rkt's frame
;; table, one arm per table entry (constants as stamped in wire_gen.js).
(define (js-frame-const sym)
  (string-replace (symbol->string sym) "-" "_"))

(define js-dispatch-arms
  '((HEADERS    . "this.#onHeaders(streamId, payload);")
    (DATA       . "this.#push(streamId, { kind: \"data\", payload });")
    (HALF-CLOSE . "this.#push(streamId, { kind: \"half-close\" });")
    (TRAILERS   . "this.#terminal(streamId, payload, \"trailers\");")
    (RST        . "this.#terminal(streamId, payload, \"rst\");")))

(define (emit-js-dispatch)
  (string-append
   "switch (type) {\n"
   (apply string-append
          (for/list ([e (in-list frame-table)])
            (define arm (assoc (first e) js-dispatch-arms))
            (unless arm (error 'runtime-js "no JS dispatch arm for ~a" (first e)))
            (format "      case FrameType.~a:\n        ~a\n        break;\n"
                    (js-frame-const (first e)) (cdr arm))))
   "      default:\n        break; // unknown frame type: ignore for forward compatibility\n    }"))


(define js-webrtc-direct-body
#<<GRPC_RUNTIME_EOF
// WebRTC-Direct (libp2p-style) client->server helpers for Node:
// no ICE, no SDP exchange. The listener is identified by the
// certhash in its multiaddr; dialers pin the listener
// certificate to it. The TURN variant is the symmetric-NAT path
// (the whole DTLS session rides a TURN allocation). This is the
// generated-runtime adapter over the hand-written stack in
// webrtc/js/direct.js -- the same shape as the Rust
// `grpc_dc::webrtc_direct` module and the Go adapter
// `go/webrtc_direct.go`. Browsers cannot bind UDP: in the
// browser, use createPeer with a native RTCPeerConnection's
// relay-only datachannel instead.

import {
  DirectListener,
  directDialMultiaddr,
  directDialTurnMultiaddr,
} from "../../webrtc/js/direct.js";
import { Endpoint } from "./endpoint.js";

export { DirectListener };

/** Bind a WebRTC-Direct listener (multiaddr() is its identity). */
export async function directListener(options = {}) {
  return DirectListener.bind(options);
}

function waitForChannel(endpoint, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("webrtc-direct: no channel opened")),
      timeoutMs,
    );
    endpoint.onchannel = (channel) => {
      clearTimeout(timer);
      resolve(channel);
    };
  });
}

/**
 * Accept one direct connection and its "grpc" channel; serve
 * the returned Endpoint with `new Server().serve(endpoint)` or
 * register services on it. The server side answers with even
 * stream ids.
 */
export async function acceptDirectEndpoint(listener) {
  const endpoint = await listener.accept();
  const channel = await waitForChannel(endpoint);
  const grpcEndpoint = new Endpoint(channel, { parity: "even" });
  // The underlying stack endpoint, for close()/transport
  // control; the generated Endpoint wraps only the channel.
  grpcEndpoint.directEndpoint = endpoint;
  return grpcEndpoint;
}

/**
 * Dial a Direct listener by multiaddr and open the "grpc"
 * channel; build a generated client with
 * `new Channel(await directClientEndpoint(ma))`. The dialer
 * allocates odd stream ids.
 */
export async function directClientEndpoint(multiaddr, options = {}) {
  const endpoint = await directDialMultiaddr(multiaddr, options);
  const channel = endpoint.openChannel({ label: "grpc" });
  const grpcEndpoint = new Endpoint(channel, { parity: "odd" });
  grpcEndpoint.directEndpoint = endpoint;
  return grpcEndpoint;
}

/**
 * Dial a Direct listener by multiaddr and return the raw stack
 * endpoint (no channel opened yet), plus the TURN variant. Use
 * these to open extra application channels next to the "grpc"
 * one -- including lossy or unordered ones, via
 * `endpoint.openChannel({ label, ordered: false,
 * reliability: { kind: "retransmits", count: n } })` (or
 * `{ kind: "lifetime", ms }`). The "grpc" channel itself must
 * stay reliable and ordered: grpc-dc framing assumes in-order
 * reliable delivery, so keep directClientEndpoint's defaults
 * for gRPC traffic and use lossy channels only for application
 * data that tolerates drops and reordering. Incoming
 * application channels surface as `endpoint.onchannel`.
 */
export async function directClientStackEndpoint(multiaddr, options = {}) {
  return directDialMultiaddr(multiaddr, options);
}

export async function directClientTurnStackEndpoint(multiaddr, turn, options = {}) {
  return directDialTurnMultiaddr(multiaddr, { ...options, turn });
}

/**
 * Open an extra application channel on a stack endpoint from
 * directClientStackEndpoint / acceptDirectEndpoint's
 * directEndpoint. `params` is the stack ChannelParams shape:
 * { label, ordered?, reliability? } -- see
 * directClientStackEndpoint for lossy/unordered options.
 */
export function openDirectChannel(stackEndpoint, params = {}) {
  return stackEndpoint.openChannel(params);
}

/**
 * Dial by multiaddr through a TURN allocation (symmetric-NAT
 * path). `turn` is {address, username, password, transport?,
 * insecureSkipVerify?, requestIpv6Relay?}.
 */
export async function directClientTurnEndpoint(multiaddr, turn, options = {}) {
  const endpoint = await directDialTurnMultiaddr(multiaddr, {
    ...options,
    turn,
  });
  const channel = endpoint.openChannel({ label: "grpc" });
  const grpcEndpoint = new Endpoint(channel, { parity: "odd" });
  grpcEndpoint.directEndpoint = endpoint;
  return grpcEndpoint;
}
GRPC_RUNTIME_EOF
)

(define js-signaling-body
#<<GRPC_RUNTIME_EOF
// Browser HTTP/POST signaling client: one non-trickle exchange
// replaces a signaling server. The page creates an
// RTCPeerConnection, waits for ICE gathering to complete (so the
// offer SDP carries every candidate), POSTs it as JSON to the
// server's signaling endpoint, and applies the JSON answer.
//   POST /grpc-dc/signal  {"type":"offer","sdp":"v=0\r\n..."}
//   200                   {"type":"answer","sdp":"v=0\r\n..."}
// Browser-safe: no Node imports. The server half is
// signaling_server.js (Node) plus the generated Go/Rust adapters,
// all implementing the same contract. Auth and CORS belong to
// the host application serving the page/endpoint, not here.

import { Channel } from "./channel.js";

export const SIGNAL_PATH = "/grpc-dc/signal";

function waitIceGathering(pc, timeoutMs) {
  if (pc.iceGatheringState === "complete") return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(done, timeoutMs);
    function done() {
      clearTimeout(timer);
      pc.removeEventListener?.("icegatheringstatechange", check);
      resolve();
    }
    function check() {
      if (pc.iceGatheringState === "complete") done();
    }
    pc.addEventListener("icegatheringstatechange", check);
  });
}

function waitChannelOpen(dc, timeoutMs) {
  if (dc.readyState === "open") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("http-signaling: data channel did not open"));
    }, timeoutMs);
    function cleanup() {
      clearTimeout(timer);
      dc.removeEventListener?.("open", onOpen);
      dc.removeEventListener?.("error", onError);
    }
    function onOpen() {
      cleanup();
      resolve();
    }
    function onError() {
      cleanup();
      reject(new Error("http-signaling: data channel error"));
    }
    dc.addEventListener("open", onOpen, { once: true });
    dc.addEventListener("error", onError, { once: true });
  });
}

/**
 * POST one offer SDP to `url` and return the answer SDP string.
 * Exported for callers managing their own RTCPeerConnection.
 */
export async function signalViaHttp(url, offerSdp, fetchImpl = globalThis.fetch) {
  const { sdp } = await signalSessionViaHttp(url, offerSdp, fetchImpl);
  return sdp;
}

/**
 * POST one offer SDP to `url` and return { sdp, session }:
 * the answer SDP plus the session id for trickle candidates
 * (signalCandidateViaHttp) and ICE restarts
 * (signalRestartViaHttp). Servers without sessions return
 * session: null.
 */
export async function signalSessionViaHttp(url, offerSdp, fetchImpl = globalThis.fetch) {
  if (typeof fetchImpl !== "function") {
    throw new Error("http-signaling: fetch is not available");
  }
  const res = await fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "offer", sdp: offerSdp }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || body?.type !== "answer" || typeof body?.sdp !== "string" || !body.sdp) {
    throw new Error(`http-signaling: signaling POST failed (${res.status})`);
  }
  return { sdp: body.sdp, session: typeof body.session === "string" ? body.session : null };
}

async function postSignalingJson(fetchImpl, url, value) {
  const res = await fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(value),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    throw new Error(`http-signaling: POST ${url} failed (${res.status})`);
  }
  return body;
}

/** Trickle one ICE candidate (or "" for end-of-candidates). */
export async function signalCandidateViaHttp(url, session, candidate, fetchImpl = globalThis.fetch) {
  await postSignalingJson(fetchImpl, `${url}/candidate`, { session, candidate });
}

/** ICE-restart an existing session; returns the answer SDP. */
export async function signalRestartViaHttp(url, session, offerSdp, fetchImpl = globalThis.fetch) {
  const body = await postSignalingJson(fetchImpl, `${url}/restart`, {
    session,
    type: "offer",
    sdp: offerSdp,
  });
  if (body?.type !== "answer" || typeof body?.sdp !== "string" || !body.sdp) {
    throw new Error("http-signaling: restart POST returned no answer");
  }
  return body.sdp;
}

/**
 * Connect a browser gRPC client to a server exposing the
 * HTTP/POST signaling endpoint and return a Channel for
 * generated clients: `new EchoClient(await
 * httpSignalingChannel("/grpc-dc/signal"))`.
 * Options: iceServers, iceGatherTimeoutMs (default 10000),
 * connectTimeoutMs (default 30000), label (default "grpc"),
 * trickle (default false: skip the ICE-gathering wait and
 * POST each candidate to <url>/candidate as it arrives),
 * fetchImpl / RTCPeerConnectionImpl for tests and embedding.
 * The returned Channel carries .peerConnection, .dataChannel
 * and .signalingSession; call channel.closeSignaling() to
 * tear the peer down, or channel.restartSignaling() for an
 * ICE restart over the same session (candidates trickle the
 * same way when trickle is on).
 */
export async function httpSignalingChannel(url, options = {}) {
  const {
    iceServers = [],
    iceGatherTimeoutMs = 10000,
    connectTimeoutMs = 30000,
    label = "grpc",
    trickle = false,
    fetchImpl = globalThis.fetch,
    RTCPeerConnectionImpl = globalThis.RTCPeerConnection,
  } = options;
  if (typeof RTCPeerConnectionImpl !== "function") {
    throw new Error("http-signaling: RTCPeerConnection is not available");
  }
  const pc = new RTCPeerConnectionImpl({ iceServers });
  try {
    const dc = pc.createDataChannel(label);
    let session = null;
    let candidateQueue = [];
    let signalingChain = Promise.resolve();
    let holdCandidates = false;
    const sendCandidate = (candidate) => {
      if (!trickle) return;
      if (!session || holdCandidates) {
        candidateQueue.push(candidate);
        return;
      }
      signalingChain = signalingChain
        .then(() => signalCandidateViaHttp(url, session, candidate, fetchImpl))
        .catch(() => {});
    };
    pc.addEventListener?.("icecandidate", (event) => {
      sendCandidate(event.candidate ? event.candidate.candidate : "");
    });
    if (typeof pc === "object" && "onicecandidate" in pc && !pc.addEventListener) {
      pc.onicecandidate = (event) => {
        sendCandidate(event.candidate ? event.candidate.candidate : "");
      };
    }
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    if (!trickle) await waitIceGathering(pc, iceGatherTimeoutMs);
    const answer = await signalSessionViaHttp(url, pc.localDescription.sdp, fetchImpl);
    session = answer.session;
    await pc.setRemoteDescription({ type: "answer", sdp: answer.sdp });
    if (trickle && session) {
      const queued = candidateQueue;
      candidateQueue = [];
      for (const candidate of queued) sendCandidate(candidate);
      await signalingChain;
    }
    await waitChannelOpen(dc, connectTimeoutMs);
    const channel = new Channel(dc);
    channel.peerConnection = pc;
    channel.dataChannel = dc;
    channel.signalingSession = session;
    channel.closeSignaling = () => {
      try { dc.close(); } catch { /* already closed */ }
      try { pc.close(); } catch { /* already closed */ }
    };
    channel.restartSignaling = async () => {
      if (!session) throw new Error("http-signaling: server returned no session");
      holdCandidates = true;
      candidateQueue = [];
      try {
        await signalingChain;
        const restartOffer = await pc.createOffer({ iceRestart: true });
        await pc.setLocalDescription(restartOffer);
        if (!trickle) await waitIceGathering(pc, iceGatherTimeoutMs);
        const restartAnswer = await signalRestartViaHttp(url, session, pc.localDescription.sdp, fetchImpl);
        await pc.setRemoteDescription({ type: "answer", sdp: restartAnswer });
      } finally {
        holdCandidates = false;
      }
      if (trickle) {
        const queued = candidateQueue;
        candidateQueue = [];
        for (const candidate of queued) sendCandidate(candidate);
        await signalingChain;
      }
    };
    return channel;
  } catch (e) {
    try { pc.close(); } catch { /* already closed */ }
    throw e;
  }
}
GRPC_RUNTIME_EOF
)

(define js-rendezvous-body
#<<GRPC_RUNTIME_EOF
// Rendezvous browser channel: connect to a pre-published,
// fixed WebRTC endpoint with no signaling exchange at all.
//
// A rendezvous descriptor ({host, port, iceUfrag, icePwd,
// fingerprint}) is published beforehand by the server —
// hardcoded, in a config file, served from any static URL.
// This helper synthesizes that endpoint's SDP offer locally,
// answers it in-page, and lets the browser run ICE as the
// controlling agent (the descriptor is ICE-lite) with DTLS
// setup passive (the server presents the fingerprinted
// certificate). host must be an IP literal: candidate lines
// carry addresses, not names.

import { Channel } from "./channel.js";

function waitRendezvousChannelOpen(dc, timeoutMs) {
  if (dc.readyState === "open") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("rendezvous: data channel did not open"));
    }, timeoutMs);
    function cleanup() {
      clearTimeout(timer);
      dc.removeEventListener?.("open", onOpen);
      dc.removeEventListener?.("error", onError);
    }
    function onOpen() {
      cleanup();
      resolve();
    }
    function onError() {
      cleanup();
      reject(new Error("rendezvous: data channel error"));
    }
    dc.addEventListener("open", onOpen);
    dc.addEventListener("error", onError);
  });
}

/**
 * The endpoint's SDP offer, synthesized from a rendezvous
 * descriptor. Exported for tests and debugging.
 */
export function synthesizeRendezvousOffer(descriptor) {
  const { host, port } = descriptor;
  return [
    "v=0",
    "o=- 4611733050433952912 2 IN IP4 127.0.0.1",
    "s=-",
    "t=0 0",
    "a=group:BUNDLE 0",
    "a=ice-lite",
    `m=application ${port} UDP/DTLS/SCTP webrtc-datachannel`,
    "c=IN IP4 0.0.0.0",
    `a=candidate:1 1 udp 2130706431 ${host} ${port} typ host generation 0`,
    "a=end-of-candidates",
    `a=ice-ufrag:${descriptor.iceUfrag}`,
    `a=ice-pwd:${descriptor.icePwd}`,
    `a=fingerprint:sha-256 ${descriptor.fingerprint}`,
    `a=setup:${descriptor.setup ?? "passive"}`,
    "a=mid:0",
    "a=sctp-port:5000",
    "a=max-message-size:262144",
    "",
  ].join("\r\n");
}

// ---------------------------------------------------------------------------
// Rendezvous auth tokens: base64url(protobuf claims) + "." +
// base64url(HMAC-SHA256(secret, claims)). Claims wire layout
// (protobuf, no schema dependency): 1 sub, 2 iss, 3 aud
// (strings); 4 exp, 5 nbf, 6 iat (varint seconds); 7 scopes
// (repeated string); 8 jti (string). The same layout is
// implemented in the Go and Rust rendezvous servers, so one
// token verifies on every stack. Rendezvous-only by design:
// no protoc plugin option.

function b64urlEncode(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function b64urlDecode(text) {
  const bin = atob(text.replaceAll("-", "+").replaceAll("_", "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function pushVarint(out, value) {
  let v = BigInt(value);
  for (;;) {
    const b = Number(v & 0x7fn);
    v >>= 7n;
    if (v === 0n) { out.push(b); return; }
    out.push(b | 0x80);
  }
}

function pushLenField(out, field, bytes) {
  pushVarint(out, (field << 3) | 2);
  pushVarint(out, bytes.length);
  for (const b of bytes) out.push(b);
}

function pushVarintField(out, field, value) {
  pushVarint(out, (field << 3) | 0);
  pushVarint(out, value);
}

/** Serialize rendezvous claims to protobuf wire bytes. */
export function encodeRendezvousClaims(claims) {
  const enc = new TextEncoder();
  const out = [];
  if (claims.sub) pushLenField(out, 1, enc.encode(claims.sub));
  if (claims.iss) pushLenField(out, 2, enc.encode(claims.iss));
  if (claims.aud) pushLenField(out, 3, enc.encode(claims.aud));
  if (claims.exp) pushVarintField(out, 4, claims.exp);
  if (claims.nbf) pushVarintField(out, 5, claims.nbf);
  if (claims.iat) pushVarintField(out, 6, claims.iat);
  for (const scope of claims.scopes ?? []) pushLenField(out, 7, enc.encode(scope));
  if (claims.jti) pushLenField(out, 8, enc.encode(claims.jti));
  return new Uint8Array(out);
}

/** Parse rendezvous claims from protobuf wire bytes. */
export function decodeRendezvousClaims(bytes) {
  const dec = new TextDecoder();
  const claims = { scopes: [] };
  let pos = 0;
  const readVarint = () => {
    let v = 0n;
    let shift = 0n;
    for (;;) {
      if (pos >= bytes.length) throw new Error("truncated varint");
      const b = bytes[pos++];
      v |= BigInt(b & 0x7f) << shift;
      if ((b & 0x80) === 0) return v;
      shift += 7n;
    }
  };
  while (pos < bytes.length) {
    const tag = Number(readVarint());
    const field = tag >> 3;
    const wire = tag & 7;
    if (wire === 2) {
      const len = Number(readVarint());
      const slice = bytes.slice(pos, pos + len);
      pos += len;
      if (field === 1) claims.sub = dec.decode(slice);
      else if (field === 2) claims.iss = dec.decode(slice);
      else if (field === 3) claims.aud = dec.decode(slice);
      else if (field === 7) claims.scopes.push(dec.decode(slice));
      else if (field === 8) claims.jti = dec.decode(slice);
    } else if (wire === 0) {
      const v = Number(readVarint());
      if (field === 4) claims.exp = v;
      else if (field === 5) claims.nbf = v;
      else if (field === 6) claims.iat = v;
    } else {
      throw new Error(`unsupported wire type ${wire}`);
    }
  }
  return claims;
}

async function hmacKey(secret) {
  const raw = typeof secret === "string" ? new TextEncoder().encode(secret) : secret;
  return crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

/** Mint a rendezvous token for `claims` under `secret`. */
export async function issueRendezvousToken(secret, claims) {
  const body = encodeRendezvousClaims(claims);
  const key = await hmacKey(secret);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  return `${b64urlEncode(body)}.${b64urlEncode(sig)}`;
}

/**
 * Verify a rendezvous token and return its claims. Throws on
 * a malformed token, a bad signature, expiry (exp), a
 * not-yet-valid token (nbf), or an issuer/audience mismatch
 * when options.issuer / options.audience are set.
 * options: { issuer, audience, nowSeconds }
 */
export async function verifyRendezvousToken(secret, token, options = {}) {
  const parts = String(token).split(".");
  if (parts.length !== 2) throw new Error("malformed rendezvous token");
  const body = b64urlDecode(parts[0]);
  const sig = b64urlDecode(parts[1]);
  const key = await hmacKey(secret);
  const ok = await crypto.subtle.verify("HMAC", key, sig, body);
  if (!ok) throw new Error("bad rendezvous token signature");
  const claims = decodeRendezvousClaims(body);
  const now = options.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (claims.exp && now >= claims.exp) throw new Error("rendezvous token expired");
  if (claims.nbf && now < claims.nbf) throw new Error("rendezvous token not yet valid");
  if (options.issuer && claims.iss !== options.issuer) {
    throw new Error("rendezvous token issuer mismatch");
  }
  if (options.audience && claims.aud !== options.audience) {
    throw new Error("rendezvous token audience mismatch");
  }
  return claims;
}

/**
 * Fetch a rendezvous descriptor JSON from `url` (HTTPS in
 * production; the well-known location
 * /.well-known/grpc-dc-rendezvous.json with a short
 * Cache-Control max-age is the rotation convention — see
 * SPEC-WEBRTC.md). Returns the parsed descriptor object for
 * rendezvousChannel.
 *
 * options: { fetchImpl }
 */
export async function fetchRendezvousDescriptor(url, options = {}) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const res = await fetchImpl(url, { headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`rendezvous descriptor fetch failed: ${res.status}`);
  const descriptor = await res.json();
  for (const field of ["host", "port", "iceUfrag", "icePwd", "fingerprint"]) {
    if (descriptor[field] === undefined) {
      throw new Error(`rendezvous descriptor missing ${field}`);
    }
  }
  return descriptor;
}

/**
 * Dial a rendezvous endpoint and return a ready Channel.
 * Waits for the "grpc" DataChannel to open, matching
 * httpSignalingChannel's ready-to-use contract.
 *
 * options: { iceServers, iceTransportPolicy, timeoutMs, label,
 *   token, getToken }
 * iceTransportPolicy "relay" (with TURN iceServers) is the
 * symmetric-NAT shape: the browser nominates its relay
 * candidate against the listener's published address.
 */
export async function rendezvousChannel(descriptor, options = {}) {
  const pc = new RTCPeerConnection({
    iceServers: options.iceServers,
    iceTransportPolicy: options.iceTransportPolicy,
  });
  const dc = pc.createDataChannel(options.label ?? "grpc");
  try {
    await pc.setRemoteDescription({
      type: "offer",
      sdp: synthesizeRendezvousOffer(descriptor),
    });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await waitRendezvousChannelOpen(dc, options.timeoutMs ?? 15000);
  } catch (e) {
    pc.close();
    throw e;
  }
  const base = new Channel(dc);
  base.peerConnection = pc;
  base.dataChannel = dc;
  base.closeRendezvous = () => pc.close();
  // options.token (a string) or options.getToken (sync/async
  // () => string) attaches `authorization: Bearer <token>` to
  // every call on the returned channel; explicit per-call
  // metadata still wins.
  const getToken = options.getToken ?? (options.token ? () => options.token : null);
  if (getToken === null) return base;
  const channel = base.withMetadata(async () => {
    const token = await getToken();
    return token ? { authorization: `Bearer ${token}` } : {};
  });
  channel.peerConnection = pc;
  channel.dataChannel = dc;
  channel.closeRendezvous = () => pc.close();
  return channel;
}
GRPC_RUNTIME_EOF
)

(define js-rendezvous-server-body
#<<GRPC_RUNTIME_EOF
// Rendezvous server: one fixed, pre-published WebRTC
// endpoint browsers dial with no signaling exchange.
// Wraps the WebRTC stack's RendezvousListener: one UDP
// socket, fixed ICE credentials and DTLS certificate.
// Publish listener.descriptor(host) wherever browsers can
// find it; serve HTTP signaling instead when the server
// address cannot be fixed in advance.

import { RendezvousListener } from "../../webrtc/js/rendezvous.js";
import { verifyRendezvousToken } from "./rendezvous.js";

export { RendezvousListener } from "../../webrtc/js/rendezvous.js";

/**
 * Serve this gRPC Server to rendezvous browsers.
 *
 * options: { address, port, family, localIps, iceUfrag,
 *   icePwd, certificate, onError, consentIntervalMs,
 *   consentExpiryMs, mux } — fix iceUfrag/icePwd/
 *   certificate and the published descriptor stays stable
 *   across restarts; ephemeral values rotate per process.
 * With `mux` (a PeerMux, e.g. the one a signalingHandler
 * uses via options.mux), the listener shares the mux's UDP
 * socket instead of binding its own: one port serves both
 * HTTP-signaled and rendezvous browsers.
 * Returns the RendezvousListener (call .descriptor(host)
 * and .close()).
 */
export async function serveRendezvous(grpcServer, options = {}) {
  // options.auth {secret, scopes, issuer, audience} requires a
  // rendezvous bearer token on every call (see rendezvous.js):
  // bad/missing/expired -> UNAUTHENTICATED, under-scoped ->
  // PERMISSION_DENIED, verified claims on ctx.claims.
  if (options.auth) {
    const { secret, scopes, issuer, audience } = options.auth;
    grpcServer.requireRendezvousAuth(
      (token) => verifyRendezvousToken(secret, token, { issuer, audience }),
      scopes ?? {},
    );
  }
  const listener = await RendezvousListener.bind({
    ...options,
    onChannel: (channel, peer) => {
      if (channel.label === "grpc") {
        grpcServer.serve(channel);
        channel.onclose = () => peer.close().catch(() => {});
      } else {
        channel.close();
      }
    },
  });
  grpcServer.closeRendezvous = () => listener.close();
  return listener;
}
GRPC_RUNTIME_EOF
)

(define js-signaling-server-body
#<<GRPC_RUNTIME_EOF
// Node HTTP/POST signaling server: the server half of the
// browser signaling contract in signaling.js. Each POST creates
// a fresh Peer on the handler's shared PeerMux (one UDP socket
// for every session; options.mux supplies a process-wide one),
// answers the offer, returns the answer JSON immediately, then
// connects in the background and serves the browser's "grpc"
// DataChannel with the given generated Server. Non-trickle: the answer
// carries the peer's host candidates as created; configure
// peerOptions (localIps / stunServers / turnServers) when the
// host candidates in the answer are not reachable as-is.
// Auth and CORS belong to the host application: mount
// signalingHandler on your own HTTP server behind them, or use
// serveHttpSignaling for the standalone no-auth shape.

import { createServer } from "node:http";

import { PeerMux } from "../../webrtc/js/mux.js";

export const SIGNAL_PATH = "/grpc-dc/signal";
const MAX_SIGNAL_BODY = 1 << 20;

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_SIGNAL_BODY) throw new Error("signaling body too large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * HTTP handler for the signaling contract. Returns true when
 * the request path matched (and was handled), false otherwise,
 * so hosts can mount it alongside their own routes:
 *   const signal = signalingHandler(grpcServer);
 *   createServer((req, res) => signal(req, res).then(h => ...));
 */
export function signalingHandler(grpcServer, options = {}) {
  const path = options.path ?? SIGNAL_PATH;
  const peerOptions = options.peerOptions ?? {};
  const onError = options.onError ?? ((e) => console.error("http-signaling:", e));
  const peers = new Set();
  const sessions = new Map(); // session id -> peer (trickle/restart)
  // All session peers share one PeerMux UDP socket for the
  // life of this handler (created lazily on first POST, or
  // supplied by the host via options.mux so several signaling
  // servers in one process share one socket; a host-supplied
  // mux stays host-owned and is never closed here).
  let muxPromise = options.mux ? Promise.resolve(options.mux) : null;
  let ownsMux = !options.mux;
  const getMux = () => {
    if (!muxPromise) {
      muxPromise = PeerMux.bind(options.muxBind ?? {});
    }
    return muxPromise;
  };
  const handler = async (req, res) => {
    let pathname;
    try {
      pathname = new URL(req.url, "http://localhost").pathname;
    } catch {
      return false;
    }
    const isSignal = pathname === path;
    const isCandidate = pathname === `${path}/candidate`;
    const isRestart = pathname === `${path}/restart`;
    if (!isSignal && !isCandidate && !isRestart) return false;
    if (req.method !== "POST") {
      sendJson(res, 405, { error: "method not allowed" });
      return true;
    }
    let peer = null;
    try {
      const parsed = JSON.parse(await readBody(req));
      if (isCandidate || isRestart) {
        const sessionPeer = sessions.get(parsed?.session);
        if (!sessionPeer) {
          sendJson(res, 404, { error: "unknown session" });
          return true;
        }
        if (isCandidate) {
          if (typeof parsed?.candidate !== "string") {
            sendJson(res, 400, { error: "expected {\"session\",\"candidate\":...}" });
            return true;
          }
          sessionPeer.addRemoteCandidate(parsed.candidate);
          sendJson(res, 200, { ok: true });
          return true;
        }
        if (parsed?.type !== "offer" || typeof parsed?.sdp !== "string" || !parsed.sdp) {
          sendJson(res, 400, { error: "expected {\"session\",\"type\":\"offer\",\"sdp\":...}" });
          return true;
        }
        try {
          const answer = sessionPeer.handleRestartOffer(parsed.sdp);
          sendJson(res, 200, { type: "answer", sdp: answer, session: parsed.session });
        } catch {
          sendJson(res, 400, { error: "invalid restart offer SDP" });
        }
        return true;
      }
      if (parsed?.type !== "offer" || typeof parsed?.sdp !== "string" || !parsed.sdp) {
        sendJson(res, 400, { error: "expected {\"type\":\"offer\",\"sdp\":...}" });
        return true;
      }
      peer = await (await getMux()).createPeer(peerOptions);
      peers.add(peer);
      let answer;
      try {
        answer = peer.handleOffer(parsed.sdp);
      } catch {
        await peer.close().catch(() => {});
        peers.delete(peer);
        peer = null;
        sendJson(res, 400, { error: "invalid offer SDP" });
        return true;
      }
      const session = globalThis.crypto?.randomUUID?.() ?? `s${Date.now()}-${sessions.size}`;
      sessions.set(session, peer);
      sendJson(res, 200, { type: "answer", sdp: answer, session });
      // Background: run ICE/DTLS, then serve the grpc channel.
      const serving = peer;
      void (async () => {
        try {
          const endpoint = await serving.connect();
          endpoint.onchannel = (channel) => {
            if ((channel.label ?? "grpc") === "grpc") {
              grpcServer.serve(channel);
              // One signaling POST owns one peer: when its grpc
              // channel closes, tear the peer (socket, timers)
              // down with it instead of leaking it per request.
              channel.addEventListener?.(
                "close",
                () => {
                  peers.delete(serving);
                  sessions.delete(session);
                  void serving.close().catch(() => {});
                },
                { once: true },
              );
            }
          };
        } catch (e) {
          onError(e);
          sessions.delete(session);
          await serving.close().catch(() => {});
        }
      })();
      return true;
    } catch (e) {
      if (peer) {
        peers.delete(peer);
        await peer.close().catch(() => {});
      }
      if (!res.headersSent) sendJson(res, 500, { error: "signaling failed" });
      return true;
    }
  };
  // Hosts/tests can tear down every peer created so far (each
  // grpc channel close already closes its own peer; this is
  // the bulk shutdown path). Also exposed as closeSignaling
  // on serveHttpSignaling's returned server.
  handler.closePeers = async () => {
    const all = [...peers];
    peers.clear();
    sessions.clear();
    await Promise.all(all.map((p) => p.close().catch(() => {})));
    if (ownsMux && muxPromise) {
      const mux = await muxPromise.catch(() => null);
      muxPromise = null;
      try { mux?.close(); } catch { /* already closed */ }
    }
  };
  handler.peers = peers;
  // The shared PeerMux every session peer was created on
  // (host-supplied via options.mux, or bound lazily here).
  handler.getMux = getMux;
  return handler;
}

/**
 * Standalone signaling HTTP server on host:port (defaults
 * 127.0.0.1:8080). Requests outside the signaling path get a
 * 404 JSON body. Returns the node:http Server (await its
 * "listening" event; close() to stop). Host applications that
 * need auth/CORS should mount signalingHandler instead.
 */
export function serveHttpSignaling(grpcServer, options = {}) {
  const handler = signalingHandler(grpcServer, options);
  const server = createServer((req, res) => {
    void handler(req, res).then((handled) => {
      if (!handled && !res.headersSent) sendJson(res, 404, { error: "not found" });
    });
  });
  server.closeSignaling = handler.closePeers;
  server.getSignalingMux = handler.getMux;
  server.listen(options.port ?? 8080, options.host ?? "127.0.0.1");
  return server;
}
GRPC_RUNTIME_EOF
)

(define js-kafka-native-addon-body
#<<GRPC_RUNTIME_EOF
/* kafka_native N-API addon: pure N-API (node_api.h), no
 * external dependencies. Build:
 *   cc -O2 -fPIC -shared -I<node include dir> \
 *      -I<kafka-native include dir> kafka_native_addon.c \
 *      -L<kafka-native lib dir> -lkafka_native \
 *      -Wl,-rpath,<kafka-native lib dir> \
 *      -o kafka_native_addon.node
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#define NAPI_VERSION 8
#include <node_api.h>
#include <stdlib.h>
#include <string.h>

#include "kafka_native.h"

static char *dup_str(const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p) memcpy(p, s, n);
  return p;
}

static napi_value make_error(napi_env env, const char *msg) {
  napi_value err, msg_value;
  napi_create_string_utf8(env, msg ? msg : "kafka-native error",
                          NAPI_AUTO_LENGTH, &msg_value);
  napi_create_error(env, NULL, msg_value, &err);
  return err;
}

static napi_status get_string(napi_env env, napi_value v, char **out) {
  size_t len = 0;
  napi_status st = napi_get_value_string_utf8(env, v, NULL, 0, &len);
  if (st != napi_ok) return st;
  char *buf = (char *)malloc(len + 1);
  if (!buf) return napi_generic_failure;
  st = napi_get_value_string_utf8(env, v, buf, len + 1, &len);
  if (st != napi_ok) {
    free(buf);
    return st;
  }
  *out = buf;
  return napi_ok;
}

static bool get_opt_string(napi_env env, napi_value obj,
                           const char *name, char **out) {
  *out = NULL;
  napi_value v;
  bool has = false;
  if (napi_has_named_property(env, obj, name, &has) != napi_ok || !has)
    return true;
  if (napi_get_named_property(env, obj, name, &v) != napi_ok)
    return false;
  napi_valuetype t;
  if (napi_typeof(env, v, &t) != napi_ok) return false;
  if (t == napi_undefined || t == napi_null) return true;
  if (t != napi_string) return false;
  return get_string(env, v, out) == napi_ok;
}

static void free_handle(napi_env env, void *data, void *hint) {
  (void)env; (void)hint;
  if (data) kafka_native_free((KafkaNativeHandle *)data);
}

static void free_stream(napi_env env, void *data, void *hint) {
  (void)env; (void)hint;
  if (data) kafka_native_stream_free((KafkaNativeStream *)data);
}

/* create(broker, options?) -> external handle.
 * options: { clientId, saslMechanism, username, password,
 *   tlsCaCert, tlsServerName, tlsInsecureSkipVerify } */
static napi_value js_create(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 1) {
    napi_throw_error(env, NULL, "kafka-native: broker required");
    return NULL;
  }
  char *broker = NULL;
  if (get_string(env, argv[0], &broker) != napi_ok) {
    napi_throw_error(env, NULL, "kafka-native: broker must be a string");
    return NULL;
  }
  KafkaNativeConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.broker = broker;
  cfg.client_id = "grpc-dc-kafka-native";
  char *client_id = NULL, *mech = NULL, *user = NULL, *pass = NULL;
  char *ca = NULL, *server_name = NULL;
  if (argc >= 2) {
    napi_valuetype t;
    napi_typeof(env, argv[1], &t);
    if (t == napi_object) {
      get_opt_string(env, argv[1], "clientId", &client_id);
      get_opt_string(env, argv[1], "saslMechanism", &mech);
      get_opt_string(env, argv[1], "username", &user);
      get_opt_string(env, argv[1], "password", &pass);
      get_opt_string(env, argv[1], "tlsCaCert", &ca);
      get_opt_string(env, argv[1], "tlsServerName", &server_name);
      napi_value skip;
      bool has = false;
      if (napi_has_named_property(env, argv[1],
              "tlsInsecureSkipVerify", &has) == napi_ok && has &&
          napi_get_named_property(env, argv[1],
              "tlsInsecureSkipVerify", &skip) == napi_ok) {
        bool b = false;
        if (napi_get_value_bool(env, skip, &b) == napi_ok)
          cfg.tls_insecure_skip_verify = b ? 1 : 0;
      }
    }
  }
  if (client_id) cfg.client_id = client_id;
  cfg.sasl_mechanism = mech;
  cfg.username = user;
  cfg.password = pass;
  cfg.tls_ca_cert = ca;
  cfg.tls_server_name = server_name;
  KafkaNativeHandle *h = kafka_native_new_v2(&cfg);
  char *err = h ? NULL : dup_str(kafka_native_last_error());
  free(broker); free(client_id); free(mech); free(user);
  free(pass); free(ca); free(server_name);
  if (!h) {
    napi_throw_error(env, NULL,
                     err ? err : "kafka-native: create failed");
    free(err);
    return NULL;
  }
  napi_value ext;
  if (napi_create_external(env, h, free_handle, NULL, &ext) != napi_ok) {
    kafka_native_free(h);
    napi_throw_error(env, NULL, "kafka-native: external failed");
    return NULL;
  }
  return ext;
}

typedef struct {
  KafkaNativeHandle *handle;
  KafkaNativeStream *stream;
  char *method;
  uint8_t *req;
  size_t req_len;
  uint8_t *out;
  size_t out_len;
  int32_t rc;
  char *err;
  napi_async_work work;
  napi_deferred deferred;
} Job;

static void job_free(Job *j) {
  free(j->method);
  free(j->req);
  free(j->err);
  free(j);
}

static void call_execute(napi_env env, void *data) {
  (void)env;
  Job *j = (Job *)data;
  j->rc = kafka_native_call(j->handle, j->method, j->req,
                            j->req_len, &j->out, &j->out_len);
  if (j->rc != 0) j->err = dup_str(kafka_native_last_error());
}

static void next_execute(napi_env env, void *data) {
  (void)env;
  Job *j = (Job *)data;
  j->rc = kafka_native_stream_next(j->stream, &j->out, &j->out_len);
  if (j->rc < 0) j->err = dup_str(kafka_native_last_error());
}

static void job_complete(napi_env env, napi_status status, void *data) {
  (void)status;
  Job *j = (Job *)data;
  bool ok = (j->stream == NULL) ? (j->rc == 0) : (j->rc >= 0);
  if (ok) {
    napi_value val;
    if (j->stream != NULL && j->rc == 0) {
      napi_get_null(env, &val);
    } else if (j->out != NULL && j->out_len > 0) {
      void *buf = NULL;
      napi_create_buffer_copy(env, j->out_len, j->out, &buf, &val);
    } else {
      void *buf = NULL;
      napi_create_buffer_copy(env, 0, NULL, &buf, &val);
    }
    if (j->out) kafka_native_bytes_free(j->out, j->out_len);
    napi_resolve_deferred(env, j->deferred, val);
  } else {
    napi_value err = make_error(env, j->err);
    if (j->out) kafka_native_bytes_free(j->out, j->out_len);
    napi_reject_deferred(env, j->deferred, err);
  }
  napi_delete_async_work(env, j->work);
  job_free(j);
}

static napi_value start_job(napi_env env, napi_value promise_owner,
                            Job *j, napi_async_execute_callback exec,
                            const char *name) {
  napi_value promise;
  if (napi_create_promise(env, &j->deferred, &promise) != napi_ok) {
    job_free(j);
    napi_throw_error(env, NULL, "kafka-native: promise failed");
    return NULL;
  }
  napi_value resource;
  napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource);
  if (napi_create_async_work(env, promise_owner, resource, exec,
                             job_complete, j, &j->work) != napi_ok ||
      napi_queue_async_work(env, j->work) != napi_ok) {
    napi_delete_async_work(env, j->work);
    job_free(j);
    napi_throw_error(env, NULL, "kafka-native: async work failed");
    return NULL;
  }
  return promise;
}

static bool read_bytes_arg(napi_env env, napi_value v,
                           uint8_t **out, size_t *out_len) {
  bool is_buffer = false;
  if (napi_is_buffer(env, v, &is_buffer) != napi_ok || !is_buffer) {
    /* Accept any Uint8Array via the typedarray API. */
    bool is_ta = false;
    if (napi_is_typedarray(env, v, &is_ta) != napi_ok || !is_ta)
      return false;
    napi_typedarray_type type;
    size_t length = 0;
    void *data = NULL;
    napi_value ab;
    size_t offset = 0;
    if (napi_get_typedarray_info(env, v, &type, &length, &data,
                                 &ab, &offset) != napi_ok)
      return false;
    if (type != napi_uint8_array) return false;
    *out_len = length;
    *out = (uint8_t *)malloc(length ? length : 1);
    if (!*out) return false;
    if (length) memcpy(*out, data, length);
    return true;
  }
  void *data = NULL;
  size_t length = 0;
  if (napi_get_buffer_info(env, v, &data, &length) != napi_ok)
    return false;
  *out_len = length;
  *out = (uint8_t *)malloc(length ? length : 1);
  if (!*out) return false;
  if (length) memcpy(*out, data, length);
  return true;
}

/* call(handle, method, bytes) -> Promise<Buffer> */
static napi_value js_call(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 3) {
    napi_throw_error(env, NULL, "kafka-native: call needs 3 args");
    return NULL;
  }
  void *handle = NULL;
  if (napi_get_value_external(env, argv[0], &handle) != napi_ok ||
      !handle) {
    napi_throw_error(env, NULL, "kafka-native: bad handle");
    return NULL;
  }
  Job *j = (Job *)calloc(1, sizeof(Job));
  if (!j) {
    napi_throw_error(env, NULL, "kafka-native: out of memory");
    return NULL;
  }
  j->handle = (KafkaNativeHandle *)handle;
  if (get_string(env, argv[1], &j->method) != napi_ok ||
      !read_bytes_arg(env, argv[2], &j->req, &j->req_len)) {
    job_free(j);
    napi_throw_error(env, NULL, "kafka-native: bad call arguments");
    return NULL;
  }
  return start_job(env, argv[0], j, call_execute, "kafkaNativeCall");
}

/* streamNew(handle, method, bytes) -> external stream */
static napi_value js_stream_new(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 3) {
    napi_throw_error(env, NULL, "kafka-native: streamNew needs 3 args");
    return NULL;
  }
  void *handle = NULL;
  if (napi_get_value_external(env, argv[0], &handle) != napi_ok ||
      !handle) {
    napi_throw_error(env, NULL, "kafka-native: bad handle");
    return NULL;
  }
  char *method = NULL;
  uint8_t *req = NULL;
  size_t req_len = 0;
  if (get_string(env, argv[1], &method) != napi_ok ||
      !read_bytes_arg(env, argv[2], &req, &req_len)) {
    free(method); free(req);
    napi_throw_error(env, NULL, "kafka-native: bad stream arguments");
    return NULL;
  }
  KafkaNativeStream *s = kafka_native_stream_new(
      (KafkaNativeHandle *)handle, method, req, req_len);
  char *err = s ? NULL : dup_str(kafka_native_last_error());
  free(method); free(req);
  if (!s) {
    napi_throw_error(env, NULL,
                     err ? err : "kafka-native: stream failed");
    free(err);
    return NULL;
  }
  napi_value ext;
  if (napi_create_external(env, s, free_stream, NULL, &ext) != napi_ok) {
    kafka_native_stream_free(s);
    napi_throw_error(env, NULL, "kafka-native: external failed");
    return NULL;
  }
  return ext;
}

/* streamNext(stream) -> Promise<Buffer|null> */
static napi_value js_stream_next(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
  if (argc < 1) {
    napi_throw_error(env, NULL, "kafka-native: streamNext needs 1 arg");
    return NULL;
  }
  void *stream = NULL;
  if (napi_get_value_external(env, argv[0], &stream) != napi_ok ||
      !stream) {
    napi_throw_error(env, NULL, "kafka-native: bad stream");
    return NULL;
  }
  Job *j = (Job *)calloc(1, sizeof(Job));
  if (!j) {
    napi_throw_error(env, NULL, "kafka-native: out of memory");
    return NULL;
  }
  j->stream = (KafkaNativeStream *)stream;
  return start_job(env, argv[0], j, next_execute, "kafkaNativeStreamNext");
}

static napi_value js_last_error(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value v;
  const char *msg = kafka_native_last_error();
  napi_create_string_utf8(env, msg ? msg : "", NAPI_AUTO_LENGTH, &v);
  return v;
}

static napi_value init_module(napi_env env, napi_value exports) {
  napi_value fn;
  napi_create_function(env, "create", NAPI_AUTO_LENGTH, js_create,
                       NULL, &fn);
  napi_set_named_property(env, exports, "create", fn);
  napi_create_function(env, "call", NAPI_AUTO_LENGTH, js_call,
                       NULL, &fn);
  napi_set_named_property(env, exports, "call", fn);
  napi_create_function(env, "streamNew", NAPI_AUTO_LENGTH,
                       js_stream_new, NULL, &fn);
  napi_set_named_property(env, exports, "streamNew", fn);
  napi_create_function(env, "streamNext", NAPI_AUTO_LENGTH,
                       js_stream_next, NULL, &fn);
  napi_set_named_property(env, exports, "streamNext", fn);
  napi_create_function(env, "lastError", NAPI_AUTO_LENGTH,
                       js_last_error, NULL, &fn);
  napi_set_named_property(env, exports, "lastError", fn);
  return exports;
}

NAPI_MODULE(kafka_native_addon, init_module)
GRPC_RUNTIME_EOF
)

(define js-kafka-native-body
#<<GRPC_RUNTIME_EOF
// In-process Kafka client via libkafka_native (native only).
//
// The collapsed form of the Kafka proxy: the Kafka protocol
// implementation runs in this process through the
// kafka-native N-API addon, instead of in a kafka_proxy
// sidecar reached over gRPC. Method surface mirrors the
// generated KafkaClient; requests and responses are the
// same generated kafka_pb.js messages.
//
// The addon is pure N-API C (kafka_native_addon.c next to
// this file); build it once per platform:
//   cc -O2 -fPIC -shared -I<node include dir> \
//      -I<kafka-native include dir> kafka_native_addon.c \
//      -L<kafka-native lib dir> -lkafka_native \
//      -Wl,-rpath,<kafka-native lib dir> \
//      -o kafka_native_addon.node
// Addon location: options.addon, the
// GRPC_DC_KAFKA_NATIVE_ADDON environment variable, or
// kafka_native_addon.node next to this file.

import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as pb from "./kafka_pb.js";

const require = createRequire(import.meta.url);

const UNARY = {
  Metadata: "MetadataResponse",
  OpenProducer: "OpenProducerResponse",
  CloseProducer: "CloseProducerResponse",
  EndTransaction: "EndTransactionResponse",
  Produce: "ProduceResponse",
  ListOffsets: "ListOffsetsResponse",
  CommitOffset: "CommitOffsetResponse",
  FetchOffset: "FetchOffsetResponse",
  CreateTopics: "CreateTopicsResponse",
  DeleteTopics: "DeleteTopicsResponse",
  DescribeConfigs: "DescribeConfigsResponse",
  AlterConfigs: "AlterConfigsResponse",
  CreatePartitions: "CreatePartitionsResponse",
  DeleteRecords: "DeleteRecordsResponse",
  ListGroups: "ListGroupsResponse",
  DescribeGroups: "DescribeGroupsResponse",
  DeleteGroups: "DeleteGroupsResponse",
  DeleteGroupOffsets: "DeleteGroupOffsetsResponse",
  DescribeAcls: "DescribeAclsResponse",
  CreateAcls: "CreateAclsResponse",
  DeleteAcls: "DeleteAclsResponse",
  ListTransactions: "ListTransactionsResponse",
  DescribeTransactions: "DescribeTransactionsResponse",
  DescribeShareGroups: "DescribeShareGroupsResponse",
  OpenShareGroup: "OpenShareGroupResponse",
  SharePoll: "SharePollResponse",
  ShareAck: "ShareAckResponse",
  CloseShareGroup: "CloseShareGroupResponse",
};

const STREAMS = {
  Consume: "ConsumeResponse",
  Subscribe: "GroupSubscribeResponse",
};

function loadAddon(options) {
  const candidates = [];
  if (options.addon) candidates.push(options.addon);
  if (process.env.GRPC_DC_KAFKA_NATIVE_ADDON) {
    candidates.push(process.env.GRPC_DC_KAFKA_NATIVE_ADDON);
  }
  candidates.push(
    join(dirname(fileURLToPath(import.meta.url)),
         "kafka_native_addon.node"));
  let lastErr = null;
  for (const path of candidates) {
    try {
      return require(path);
    } catch (err) {
      lastErr = err;
    }
  }
  throw new Error(
    `kafka-native: addon not loadable (${lastErr?.message}); ` +
    "build kafka_native_addon.c (see header comment)");
}

export class KafkaNativeStream {
  #addon;
  #stream;
  #respClass;
  #done = false;

  constructor(addon, stream, respClass) {
    this.#addon = addon;
    this.#stream = stream;
    this.#respClass = respClass;
  }

  /** Next chunk, or null at end of stream. */
  async next() {
    if (this.#done) return null;
    const bytes = await this.#addon.streamNext(this.#stream);
    if (bytes === null) {
      this.#done = true;
      return null;
    }
    return this.#respClass.decode(new Uint8Array(bytes));
  }

  close() {
    this.#done = true;
  }

  async *[Symbol.asyncIterator]() {
    for (;;) {
      const chunk = await this.next();
      if (chunk === null) return;
      yield chunk;
    }
  }
}

export class KafkaNativeClient {
  #addon;
  #handle;

  /**
   * broker: "host:port". options: { clientId, addon,
   * saslMechanism, username, password, tlsCaCert,
   * tlsServerName, tlsInsecureSkipVerify }.
   */
  constructor(broker, options = {}) {
    this.#addon = loadAddon(options);
    this.#handle = this.#addon.create(broker, options);
  }

  close() {
    this.#handle = null;
  }

  async #call(method, request) {
    if (!this.#handle) throw new Error("kafka-native: client closed");
    const bytes = await this.#addon.call(
      this.#handle, method, request.constructor.encode(request));
    return pb[UNARY[method]].decode(new Uint8Array(bytes));
  }

  #stream(method, request) {
    if (!this.#handle) throw new Error("kafka-native: client closed");
    const stream = this.#addon.streamNew(
      this.#handle, method, request.constructor.encode(request));
    return new KafkaNativeStream(
      this.#addon, stream, pb[STREAMS[method]]);
  }

  async metadata(request) { return this.#call("Metadata", request); }
  async openProducer(request) { return this.#call("OpenProducer", request); }
  async closeProducer(request) { return this.#call("CloseProducer", request); }
  async endTransaction(request) { return this.#call("EndTransaction", request); }
  async produce(request) { return this.#call("Produce", request); }
  consume(request) { return this.#stream("Consume", request); }
  subscribe(request) { return this.#stream("Subscribe", request); }
  async listOffsets(request) { return this.#call("ListOffsets", request); }
  async commitOffset(request) { return this.#call("CommitOffset", request); }
  async fetchOffset(request) { return this.#call("FetchOffset", request); }
  async createTopics(request) { return this.#call("CreateTopics", request); }
  async deleteTopics(request) { return this.#call("DeleteTopics", request); }
  async describeConfigs(request) { return this.#call("DescribeConfigs", request); }
  async alterConfigs(request) { return this.#call("AlterConfigs", request); }
  async createPartitions(request) { return this.#call("CreatePartitions", request); }
  async deleteRecords(request) { return this.#call("DeleteRecords", request); }
  async listGroups(request) { return this.#call("ListGroups", request); }
  async describeGroups(request) { return this.#call("DescribeGroups", request); }
  async deleteGroups(request) { return this.#call("DeleteGroups", request); }
  async deleteGroupOffsets(request) { return this.#call("DeleteGroupOffsets", request); }
  async describeAcls(request) { return this.#call("DescribeAcls", request); }
  async createAcls(request) { return this.#call("CreateAcls", request); }
  async deleteAcls(request) { return this.#call("DeleteAcls", request); }
  async listTransactions(request) { return this.#call("ListTransactions", request); }
  async describeTransactions(request) { return this.#call("DescribeTransactions", request); }
  async describeShareGroups(request) { return this.#call("DescribeShareGroups", request); }
  async openShareGroup(request) { return this.#call("OpenShareGroup", request); }
  async sharePoll(request) { return this.#call("SharePoll", request); }
  async shareAck(request) { return this.#call("ShareAck", request); }
  async closeShareGroup(request) { return this.#call("CloseShareGroup", request); }
}
GRPC_RUNTIME_EOF
)

(define (emit-js-runtime-files)
  (list
   (cons "codec.js" js-codec-body)
   (cons "kafka_native.js" js-kafka-native-body)
   (cons "kafka_native_addon.c" js-kafka-native-addon-body)
   (cons "endpoint.js"
         (string-replace js-endpoint-body "@@FRAME_DISPATCH@@" (emit-js-dispatch)))
   (cons "channel.js" js-channel-body)
   (cons "server.js" js-server-body)
   (cons "chunking.js" js-chunking-body)
   (cons "loopback.js" js-loopback-body)
   (cons "wasm_bridge.js" js-wasm-bridge-body)
   (cons "dynamic.js" js-dynamic-body)
   (cons "webrtc_direct.js" js-webrtc-direct-body)
   (cons "signaling.js" js-signaling-body)
   (cons "signaling_server.js" js-signaling-server-body)
   (cons "rendezvous.js" js-rendezvous-body)
   (cons "rendezvous_server.js" js-rendezvous-server-body)
   (cons "stdio.js" js-stdio-body)
   (cons "registry.js" js-registry-body)))

(define js-registry-body
#<<GRPC_RUNTIME_EOF
// Registry discovery service (grpcdc.registry.v1.Registry):
// ListServices answers from the host Server's live
// registrations plus descriptor-only names recorded here;
// GetDescriptor returns FileDescriptorSet bytes registered
// for a name. The service's own descriptor set is embedded
// (proto/registry.proto), so no codegen is needed to serve
// or call it: parse it with parseDescriptorSet and use a
// DynamicClient.

import { GenericMessage, createDynamicService, parseDescriptorSet } from "./dynamic.js";
import { StatusCode, StatusError } from "./codec.js";

export const REGISTRY_DESCRIPTOR_SET = Uint8Array.from(
  atob("CrkDCg5yZWdpc3RyeS5wcm90bxISZ3JwY2RjLnJlZ2lzdHJ5LnYxIhUKE0xpc3RTZXJ2aWNlc1JlcXVlc3QiMgoUTGlzdFNlcnZpY2VzUmVzcG9uc2USGgoIc2VydmljZXMYASADKAlSCHNlcnZpY2VzIioKFEdldERlc2NyaXB0b3JSZXF1ZXN0EhIKBG5hbWUYASABKAlSBG5hbWUiPgoVR2V0RGVzY3JpcHRvclJlc3BvbnNlEiUKDmRlc2NyaXB0b3Jfc2V0GAEgASgMUg1kZXNjcmlwdG9yU2V0MtMBCghSZWdpc3RyeRJhCgxMaXN0U2VydmljZXMSJy5ncnBjZGMucmVnaXN0cnkudjEuTGlzdFNlcnZpY2VzUmVxdWVzdBooLmdycGNkYy5yZWdpc3RyeS52MS5MaXN0U2VydmljZXNSZXNwb25zZRJkCg1HZXREZXNjcmlwdG9yEiguZ3JwY2RjLnJlZ2lzdHJ5LnYxLkdldERlc2NyaXB0b3JSZXF1ZXN0GikuZ3JwY2RjLnJlZ2lzdHJ5LnYxLkdldERlc2NyaXB0b3JSZXNwb25zZWIGcHJvdG8z"),
  (c) => c.charCodeAt(0),
);

/**
 * Create the Registry service definition for `server`.
 * `descriptors` is a Map<string, Uint8Array> of service
 * name to FileDescriptorSet bytes. Serve the result with
 * server.addService(...) like any generated service.
 */
export function createRegistryService(server, descriptors = new Map()) {
  const model = parseDescriptorSet(REGISTRY_DESCRIPTOR_SET);
  return createDynamicService(model, "grpcdc.registry.v1.Registry", {
    async unary(ctx, method, req) {
      const resp = new GenericMessage(method.output);
      if (method.name === "ListServices") {
        const names = new Set(server.registeredServices());
        for (const name of descriptors.keys()) names.add(name);
        for (const name of [...names].sort()) resp.add(1, name);
        return resp;
      }
      if (method.name === "GetDescriptor") {
        const name = req.getString(1);
        const bytes = descriptors.get(name);
        if (!bytes) {
          throw new StatusError(StatusCode.NOT_FOUND, `no descriptor for ${name}`);
        }
        resp.set(1, bytes);
        return resp;
      }
      throw new StatusError(StatusCode.UNIMPLEMENTED, "registry method");
    },
  });
}
GRPC_RUNTIME_EOF
)

(define js-stdio-body
#<<GRPC_RUNTIME_EOF
// IPC transports (Node only): stdio and Unix domain socket
// channels for host/plugin use. One message is a 4-byte
// big-endian length prefix plus the frame bytes — the same
// framing as the Rust StreamDc and Go SidecarTransport IPC
// forms, so a plugin process in any language can speak
// grpc-dc to a host without a WebRTC stack. Like
// rendezvous_server.js this module is Node-only and is not
// re-exported from index.js; import it directly:
//   import { stdioChannel, udsChannel } from "grpc-dc/stdio";

import net from "node:net";
import { Duplex } from "node:stream";
import { Channel } from "./channel.js";

/** DataChannel-shaped IPC endpoint over a Duplex stream. */
export class StreamDataChannel extends EventTarget {
  #inbox = Buffer.alloc(0);
  #stream;

  constructor(stream) {
    super();
    this.#stream = stream;
    stream.on("data", (chunk) => {
      this.#inbox = Buffer.concat([this.#inbox, chunk]);
      for (;;) {
        if (this.#inbox.length < 4) return;
        const len = this.#inbox.readUInt32BE(0);
        if (this.#inbox.length < 4 + len) return;
        const frame = this.#inbox.subarray(4, 4 + len);
        this.#inbox = this.#inbox.subarray(4 + len);
        this.dispatchEvent(new MessageEvent("message", { data: frame }));
      }
    });
    stream.on("error", (err) => {
      this.dispatchEvent(new ErrorEvent("error", { error: err }));
    });
  }

  send(frameBytes) {
    const frame = Buffer.isBuffer(frameBytes) ? frameBytes : Buffer.from(frameBytes);
    const prefix = Buffer.alloc(4);
    prefix.writeUInt32BE(frame.length, 0);
    this.#stream.write(Buffer.concat([prefix, frame]));
  }

  close() {
    this.#stream.end();
  }
}

/** Channel over this process's stdin/stdout (plugin side). */
export function stdioChannel() {
  const stream = Duplex.from({ readable: process.stdin, writable: process.stdout });
  return new Channel(new StreamDataChannel(stream));
}

/** Channel over a Unix domain socket at `path` (plugin side). */
export async function udsChannel(path) {
  const socket = await new Promise((resolve, reject) => {
    const s = net.createConnection(path);
    s.once("connect", () => resolve(s));
    s.once("error", reject);
  });
  return new Channel(new StreamDataChannel(socket));
}

/** Accept one Unix socket connection as a Channel (host side). */
export async function udsServerChannel(path) {
  const socket = await new Promise((resolve, reject) => {
    const server = net.createServer((s) => {
      server.close();
      resolve(s);
    });
    server.once("error", reject);
    server.listen(path);
  });
  return new Channel(new StreamDataChannel(socket));
}
GRPC_RUNTIME_EOF
)

(define js-dynamic-body
#<<GRPC_RUNTIME_EOF
// Dynamic, descriptor-driven client and server.
//
// Parses a FileDescriptorSet (as produced by
// `protoc --descriptor_set_out`) at runtime and builds clients and
// servers whose messages are generic field maps — no generated stubs
// required. Schemas arrive as data (descriptor.proto), not as code.
//
// Generic values by field type: varint family -> number, string ->
// string, bytes -> Uint8Array, message -> Map, fixed/float -> number,
// bool -> boolean. GenericMessage wraps Map<number, values[]>.

import { StatusError } from "./codec.js";
import { StatusCode } from "../wire_gen.js";

export const FieldType = {
  DOUBLE: 1, FLOAT: 2, INT64: 3, UINT64: 4, INT32: 5, FIXED64: 6,
  FIXED32: 7, BOOL: 8, STRING: 9, GROUP: 10, MESSAGE: 11, BYTES: 12,
  UINT32: 13, ENUM: 14, SFIXED32: 15, SFIXED64: 16, SINT32: 17,
  SINT64: 18,
};

const VARINT_TYPES = new Set([3, 4, 5, 8, 13, 14, 17, 18]);
const WIRE_TYPE = new Map();
for (const t of VARINT_TYPES) WIRE_TYPE.set(t, 0);
for (const t of [6, 16, 1]) WIRE_TYPE.set(t, 1);
for (const t of [9, 11, 12, 10]) WIRE_TYPE.set(t, 2);
for (const t of [7, 15, 2]) WIRE_TYPE.set(t, 5);

const LABEL_REPEATED = 3;

class PbReader {
  constructor(buf) {
    this.buf = buf;
    this.pos = 0;
  }

  varint() {
    let result = 0n;
    let shift = 0n;
    for (;;) {
      if (this.pos >= this.buf.length) throw new Error("truncated varint");
      const b = this.buf[this.pos++];
      result |= BigInt(b & 0x7f) << shift;
      if ((b & 0x80) === 0) return result;
      shift += 7n;
      if (shift >= 70n) throw new Error("varint too long");
    }
  }

  bytesField() {
    const n = Number(this.varint());
    if (this.pos + n > this.buf.length) throw new Error("truncated bytes field");
    const out = this.buf.subarray(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }

  *fields() {
    while (this.pos < this.buf.length) {
      const start = this.pos;
      const tag = this.varint();
      const number = Number(tag >> 3n);
      const wire = Number(tag & 7n);
      if (wire === 0) {
        const v = this.varint();
        yield [number, wire, v, this.buf.slice(start, this.pos)];
      } else if (wire === 2) {
        const v = this.bytesField();
        yield [number, wire, v, this.buf.slice(start, this.pos)];
      } else if (wire === 1) {
        if (this.pos + 8 > this.buf.length) throw new Error("truncated fixed64");
        const value = this.buf.subarray(this.pos, this.pos + 8);
        this.pos += 8;
        yield [number, wire, value, this.buf.slice(start, this.pos)];
      } else if (wire === 5) {
        if (this.pos + 4 > this.buf.length) throw new Error("truncated fixed32");
        const value = this.buf.subarray(this.pos, this.pos + 4);
        this.pos += 4;
        yield [number, wire, value, this.buf.slice(start, this.pos)];
      } else {
        throw new Error(`unsupported wire type ${wire}`);
      }
    }
  }
}

function pbString(fields, number) {
  for (const [num, , value] of fields) {
    if (num === number) return new TextDecoder().decode(value);
  }
  return "";
}

function pbUint(fields, number) {
  for (const [num, , value] of fields) {
    if (num === number) return value;
  }
  return 0n;
}

export class GenericMessage {
  constructor(model = null) {
    this.model = model;
    this.values = new Map();
    // Raw encoded chunks of fields not in the model (protobuf
    // unknown-field retention); re-emitted after known fields.
    this.unknown = [];
  }

  set(number, value) {
    this.values.set(number, [value]);
    return this;
  }

  add(number, value) {
    if (!this.values.has(number)) this.values.set(number, []);
    this.values.get(number).push(value);
    return this;
  }

  getAll(number) {
    return [...(this.values.get(number) ?? [])];
  }

  get(number, fallback = undefined) {
    const items = this.values.get(number);
    return items && items.length ? items[0] : fallback;
  }

  getString(number, fallback = "") {
    const value = this.get(number);
    return typeof value === "string" ? value : fallback;
  }

  getInt(number, fallback = 0) {
    const value = this.get(number);
    return typeof value === "number" ? value : fallback;
  }
}

function encodeVarint(value) {
  let v = BigInt(value) & 0xffffffffffffffffn;
  const out = [];
  while (v > 0x7fn) {
    out.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  out.push(Number(v));
  return Uint8Array.from(out);
}

function concatBytes(parts) {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

function encodeValue(field, value, fileModel) {
  const wire = WIRE_TYPE.get(field.type);
  const parts = [encodeVarint(BigInt((field.number << 3) | wire))];
  if (wire === 0) {
    if (field.type === FieldType.SINT32 || field.type === FieldType.SINT64) {
      const v = BigInt(value);
      parts.push(encodeVarint((v << 1n) ^ (v >> 63n)));
    } else if (field.type === FieldType.BOOL) {
      parts.push(encodeVarint(value ? 1 : 0));
    } else {
      parts.push(encodeVarint(BigInt(value)));
    }
  } else if (wire === 1) {
    const buf = new Uint8Array(8);
    const view = new DataView(buf.buffer);
    if (field.type === FieldType.DOUBLE) view.setFloat64(0, value, true);
    else view.setBigUint64(0, BigInt(value), true);
    parts.push(buf);
  } else if (wire === 5) {
    const buf = new Uint8Array(4);
    const view = new DataView(buf.buffer);
    if (field.type === FieldType.FLOAT) view.setFloat32(0, value, true);
    else view.setUint32(0, value, true);
    parts.push(buf);
  } else {
    let data;
    if (field.type === FieldType.STRING) data = new TextEncoder().encode(value);
    else if (field.type === FieldType.MESSAGE) {
      data = encodeGeneric(fileModel.messages.get(field.typeName), value, fileModel);
    } else data = value;
    parts.push(encodeVarint(data.length), data);
  }
  return concatBytes(parts);
}

export function encodeGeneric(model, message, fileModel) {
  const parts = [];
  const numbers = [...message.values.keys()].sort((a, b) => a - b);
  for (const number of numbers) {
    const field = model.fields.get(number);
    if (!field) {
      throw new StatusError(StatusCode.INVALID_ARGUMENT, `unknown field ${number} for ${model.fullName}`);
    }
    const values = message.values.get(number);
    if (field.repeated) {
      for (const value of values) parts.push(encodeValue(field, value, fileModel));
    } else if (values.length) {
      parts.push(encodeValue(field, values[0], fileModel));
    }
  }
  for (const chunk of message.unknown ?? []) parts.push(chunk);
  return concatBytes(parts);
}

function decodeValue(field, wire, raw, fileModel) {
  if (wire === 0) {
    if (field.type === FieldType.BOOL) return raw !== 0n;
    if (field.type === FieldType.SINT32 || field.type === FieldType.SINT64) {
      return Number((raw >> 1n) ^ -(raw & 1n));
    }
    if (field.type === FieldType.INT32 || field.type === FieldType.ENUM) {
      return Number(BigInt.asIntN(32, raw));
    }
    if (field.type === FieldType.INT64) return Number(BigInt.asIntN(64, raw));
    return Number(raw);
  }
  if (wire === 1) {
    const view = new DataView(raw.buffer, raw.byteOffset, 8);
    if (field.type === FieldType.DOUBLE) return view.getFloat64(0, true);
    return Number(view.getBigUint64(0, true));
  }
  if (wire === 5) {
    const view = new DataView(raw.buffer, raw.byteOffset, 4);
    if (field.type === FieldType.FLOAT) return view.getFloat32(0, true);
    return view.getUint32(0, true);
  }
  if (field.type === FieldType.STRING) return new TextDecoder().decode(raw);
  if (field.type === FieldType.MESSAGE) {
    return decodeGeneric(fileModel.messages.get(field.typeName), raw, fileModel);
  }
  return new Uint8Array(raw);
}

export function decodeGeneric(model, data, fileModel) {
  const message = new GenericMessage(model);
  for (const [number, wire, raw, chunk] of new PbReader(data).fields()) {
    const field = model.fields.get(number);
    if (!field) {
      // Unknown field: retain the raw encoded chunk verbatim.
      message.unknown.push(chunk);
      continue;
    }
    if (!message.values.has(number)) message.values.set(number, []);
    message.values.get(number).push(decodeValue(field, wire, raw, fileModel));
  }
  return message;
}

export function parseDescriptorSet(data) {
  const fileModel = { messages: new Map(), services: new Map() };
  const pending = [];
  for (const [number, , fileBytes] of new PbReader(data).fields()) {
    if (number !== 1) continue;
    const fields = [...new PbReader(fileBytes).fields()];
    const pkg = pbString(fields, 2);
    for (const [fnum, , fval] of fields) {
      if (fnum === 4) parseMessage(pkg, "", fval, fileModel);
      else if (fnum === 6) pending.push([pkg, fval]);
    }
  }
  for (const [pkg, serviceBytes] of pending) {
    parseService(pkg, serviceBytes, fileModel);
  }
  return fileModel;
}

function parseMessage(pkg, outer, data, fileModel) {
  const fields = [...new PbReader(data).fields()];
  const name = pbString(fields, 1);
  const full = (pkg ? pkg + "." : "") + (outer ? outer + "." : "") + name;
  const model = { fullName: full, fields: new Map() };
  fileModel.messages.set("." + full, model);
  for (const [fnum, , fval] of fields) {
    if (fnum === 2) {
      const field = parseField(fval);
      model.fields.set(field.number, field);
    } else if (fnum === 3) {
      parseMessage(pkg, full.slice(pkg ? pkg.length + 1 : 0), fval, fileModel);
    }
  }
  return model;
}

function parseField(data) {
  const fields = [...new PbReader(data).fields()];
  return {
    number: Number(pbUint(fields, 3)),
    name: pbString(fields, 1),
    type: Number(pbUint(fields, 5)),
    repeated: Number(pbUint(fields, 4)) === LABEL_REPEATED,
    typeName: pbString(fields, 6),
  };
}

function methodKind(clientStreaming, serverStreaming) {
  if (clientStreaming && serverStreaming) return "bidi";
  if (serverStreaming) return "server-streaming";
  if (clientStreaming) return "client-streaming";
  return "unary";
}

function parseService(pkg, data, fileModel) {
  const fields = [...new PbReader(data).fields()];
  const name = pbString(fields, 1);
  const full = pkg ? `${pkg}.${name}` : name;
  const service = { fullName: full, methods: new Map() };
  fileModel.services.set(full, service);
  for (const [fnum, , fval] of fields) {
    if (fnum !== 2) continue;
    const mf = [...new PbReader(fval).fields()];
    const mname = pbString(mf, 1);
    service.methods.set(mname, {
      name: mname,
      path: `/${full}/${mname}`,
      kind: methodKind(pbUint(mf, 5) !== 0n, pbUint(mf, 6) !== 0n),
      input: fileModel.messages.get(pbString(mf, 2)),
      output: fileModel.messages.get(pbString(mf, 3)),
    });
  }
  return service;
}

function boundType(model, fileModel) {
  return {
    encode: (generic) => encodeGeneric(model, generic ?? new GenericMessage(model), fileModel),
    decode: (bytes) => decodeGeneric(model, bytes, fileModel),
  };
}

/** Runtime-built client: methods resolve from the file model. */
export class DynamicClient {
  #channel;
  #model;

  constructor(channel, fileModel) {
    this.#channel = channel;
    this.#model = fileModel;
  }

  #method(serviceName, methodName) {
    const service = this.#model.services.get(serviceName);
    if (!service) throw new StatusError(StatusCode.INVALID_ARGUMENT, `unknown service ${serviceName}`);
    const method = service.methods.get(methodName);
    if (!method) throw new StatusError(StatusCode.INVALID_ARGUMENT, `unknown method ${methodName}`);
    return method;
  }

  async unary(serviceName, methodName, request, { metadata } = {}) {
    const method = this.#method(serviceName, methodName);
    return this.#channel.unary(method.path, request,
      boundType(method.input, this.#model), boundType(method.output, this.#model), { metadata });
  }

  async serverStream(serviceName, methodName, request, { metadata } = {}) {
    const method = this.#method(serviceName, methodName);
    return this.#channel.serverStream(method.path, request,
      boundType(method.input, this.#model), boundType(method.output, this.#model), { metadata });
  }

  async clientStream(serviceName, methodName, requests, { metadata } = {}) {
    const method = this.#method(serviceName, methodName);
    return this.#channel.clientStream(method.path, requests,
      boundType(method.input, this.#model), boundType(method.output, this.#model), { metadata });
  }

  async bidi(serviceName, methodName, requests, { metadata } = {}) {
    const method = this.#method(serviceName, methodName);
    return this.#channel.bidi(method.path, requests,
      boundType(method.input, this.#model), boundType(method.output, this.#model), { metadata });
  }
}

/**
 * Build a Server service definition from descriptors + a handler
 * object with methods by kind:
 *   unary(ctx, method, request) -> GenericMessage
 *   serverStream(ctx, method, request) -> iterable/async iterable of GenericMessage
 *   clientStream(ctx, method, requests) -> GenericMessage
 *   bidi(ctx, method, requests) -> iterable/async iterable of GenericMessage
 * (requests are async iterables of GenericMessage.) Pass the result
 * to server.addService(definition).
 */
export function createDynamicService(fileModel, serviceName, handler) {
  const service = fileModel.services.get(serviceName);
  if (!service) throw new StatusError(StatusCode.INVALID_ARGUMENT, `unknown service ${serviceName}`);
  const methods = {};
  for (const method of service.methods.values()) {
    methods[method.name] = {
      path: method.path,
      kind: method.kind,
      requestType: boundType(method.input, fileModel),
      responseType: boundType(method.output, fileModel),
      handler: async (...args) => {
        if (method.kind === "unary") {
          const [req, ctx] = args;
          return handler.unary(ctx, method, req);
        }
        if (method.kind === "server-streaming") {
          const [req, ctx] = args;
          return handler.serverStream(ctx, method, req);
        }
        if (method.kind === "client-streaming") {
          const [requests, ctx] = args;
          return handler.clientStream(ctx, method, requests);
        }
        const [requests, ctx] = args;
        return handler.bidi(ctx, method, requests);
      },
    };
  }
  return { name: service.fullName, methods };
}
GRPC_RUNTIME_EOF
)
