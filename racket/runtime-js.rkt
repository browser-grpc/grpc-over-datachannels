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

  // A Channel view sharing this endpoint whose outbound spans are
  // parented to traceContext (a server span context from
  // ctx.traceContext, or a root from newTraceContext). Explicit
  // call metadata still wins. This is the browser-safe propagation
  // path: no ambient async context is assumed.
  withTraceContext(traceContext) {
    const ch = new Channel(this.#endpoint);
    ch.#traceContext = traceContext ?? null;
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

  addService(definition) {
    for (const [name, method] of Object.entries(definition.methods)) {
      if (typeof method.handler !== "function") {
        throw new Error(`grpc-dc: missing handler for ${definition.name}.${name}`);
      }
      this.#methods.set(method.path, { ...method, service: definition.name, method: name });
    }
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

(define (emit-js-runtime-files)
  (list
   (cons "codec.js" js-codec-body)
   (cons "endpoint.js"
         (string-replace js-endpoint-body "@@FRAME_DISPATCH@@" (emit-js-dispatch)))
   (cons "channel.js" js-channel-body)
   (cons "server.js" js-server-body)
   (cons "loopback.js" js-loopback-body)
   (cons "wasm_bridge.js" js-wasm-bridge-body)
   (cons "dynamic.js" js-dynamic-body)
   (cons "webrtc_direct.js" js-webrtc-direct-body)))

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
