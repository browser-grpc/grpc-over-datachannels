# Tracing examples (beta)

Multi-service tracing for grpc-dc: one W3C trace across a
client, a callee, and the downstream service the callee calls.

- `multiservice.mjs` — client → front callee → downstream
  service over in-memory DataChannels. The front handler parents
  its outbound call with `Channel.withTraceContext`, so all four
  spans (client, server, client, server) share one trace id.
  Run: `node examples/tracing/multiservice.mjs`
- `otlp.mjs` — the same nested trace, exported as OTLP/JSON by
  the example `OtlpTracer` observer. With no collector it is
  self-verifying (throwaway local collector, checks the
  four-span payload, prints `OTLP_EXAMPLE_OK`); set
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` to export to a real
  OpenTelemetry collector instead.
  Run: `node examples/tracing/otlp.mjs`

Per-language API names (registrar, handler span context,
context binding, root contexts) are generated into each
language's `TRACING.md` (for example `../../js/TRACING.md`,
`../../python/TRACING.md`, `../../go/TRACING.md`). The wire
contract is in `../../SPEC.md` (Tracing).

Single-service demos also live with the runtimes:
`tracing_demo` (span printing) and `otlp_tracer` (OTLP/JSON
export with only the standard library) in the Python and JS
example sets.
