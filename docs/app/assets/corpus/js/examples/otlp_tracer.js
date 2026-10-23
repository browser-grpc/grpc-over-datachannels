// OTLP/JSON exporter as an example span observer (not in the runtime).
//
// The generated runtimes stay dependency-free and SDK-free; this
// example shows the hooks are sufficient for a real backend. Ended
// spans are buffered and POSTed as OTLP/JSON to an OpenTelemetry
// collector (default http://localhost:4318/v1/traces) using the
// platform fetch. Export failures are swallowed: tracing must
// never break the call.
//
// Usage:
//   setTracer(new OtlpTracer({ serviceName: "echo-client" }));
//   ... make calls ...
//   await tracer.flush();

const KIND = { client: 3, server: 2 }; // OTLP SpanKind CLIENT / SERVER

export class OtlpTracer {
  constructor({
    endpoint = "http://localhost:4318/v1/traces",
    serviceName = "grpcdc",
    batchSize = 32,
    sender = null,
  } = {}) {
    this.endpoint = endpoint;
    this.serviceName = serviceName;
    this.batchSize = batchSize;
    this.sender = sender || ((payload) => this.#post(payload));
    this.open = new Map();
    this.ended = [];
  }

  onStart(kind, method, traceId, spanId, parentSpanId) {
    this.open.set(spanId, {
      traceId,
      spanId,
      parentSpanId,
      name: method,
      kind: KIND[kind] ?? 1,
      startTimeUnixNano: String(Date.now() * 1_000_000),
      attributes: [{ key: "grpcdc.kind", value: { stringValue: kind } }],
    });
  }

  onEnd(kind, method, traceId, spanId, status) {
    const span = this.open.get(spanId);
    if (!span) return;
    this.open.delete(spanId);
    span.endTimeUnixNano = String(Date.now() * 1_000_000);
    span.status = status === "OK" ? { code: 1 } : { code: 2, message: status };
    this.ended.push(span);
    if (this.ended.length >= this.batchSize) void this.flush();
  }

  payload(spans) {
    return {
      resourceSpans: [{
        resource: {
          attributes: [{
            key: "service.name",
            value: { stringValue: this.serviceName },
          }],
        },
        scopeSpans: [{ scope: { name: "grpcdc" }, spans }],
      }],
    };
  }

  async flush() {
    if (this.ended.length === 0) return;
    const spans = this.ended;
    this.ended = [];
    try {
      await this.sender(this.payload(spans));
    } catch {
      // tracing must never break the call
    }
  }

  async #post(payload) {
    await fetch(this.endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  }
}
