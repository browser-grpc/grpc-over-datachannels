# Interop oracle (grpc.testing.TestService)

Vendored from grpc-java v1.62.2 (`interop-testing`), Apache
License 2.0 (headers preserved in the files):

- `grpc/testing/test.proto` — the canonical cross-implementation
  test service (`TestService`, `UnimplementedService`)
- `grpc/testing/messages.proto`, `grpc/testing/empty.proto`

These protos are Google's interop contract, deliberately NOT
generated or edited here: our protoc plugins consume them as-is
to produce `TestService` stubs, and the official grpc-java
`TestServiceServer` (artifact `io.grpc:grpc-interop-testing`,
wired into `oracle/java/pom.xml`) serves the reference side.

Per-language interop oracle tests (generated stubs + case
drivers mirroring `AbstractInteropTest` semantics):

Direction A — our clients vs official servers (grpc-java
`TestServiceServer` and the grpc-go interop server in
`oracle/go-interop/`, both over direct HTTP/2):

- `js/test/interop_oracle.test.js`
- `python/tests/test_interop_oracle.py`
- `go/interop_oracle_test.go`

Direction B — official clients (grpc-java `TestServiceClient`,
grpc-go `interop-client`) vs our generated servers, reached
over HTTP/2 through the ingress proxy -> WebRTC-Direct:

- `js/test/interop_server_oracle.test.js` (agent serves the
  JS implementation in `js/test/interop_service.js`)
- `go/interop_server_oracle_test.go` (Go server behind the
  Node proxy CLI)
- `python/tests/test_interop_server_oracle.py` (Python server
  behind the Rust `direct_sidecar`, implementation in
  `python/tests/interop_service.py`)

Excluded cases: auth (`*_creds`, `oauth2_auth_token`,
`per_rpc_creds`) needs GCP credentials; the soak cases have
their own long-running script.

Compression runs in both directions. Client direction: the
generated HTTP/2 client transports (JS/Go/Python) gzip
requests keyed on `grpc-encoding: gzip` call metadata,
advertise `grpc-accept-encoding`, and decompress responses,
so `client_compressed_*` and `server_compressed_*` pass
against both reference servers. Server direction: the
DataChannel wire stays compression-free by design, and the
proxy terminates gzip at the HTTP/2 hop — but it surfaces the
declared encoding as ordinary metadata (`grpc-encoding`,
injected from the first request message's compressed flag
when per-message compression declares no header), so our
servers run the `expect_compressed` check, and a server
declaring `grpc-encoding: gzip` in its initial metadata gets
its response messages gzipped by the proxy. All four
compressed cases pass under the grpc-java client against
our JS/Go/Python/Rust servers. One known edge: compression that
starts mid-stream (first request message uncompressed, later
ones flagged) is always decompressed correctly by the proxy,
but the `grpc-encoding` metadata cannot be surfaced — the
request HEADERS frame already went out with the first
message — so only a per-message `expect_compressed` check
on such a stream would miss it. Payloads are never affected
(covered by the `mid-stream` proxy test).

ORCA (`orca_per_rpc`, `orca_oob`) runs in both directions:
our servers report per-request and out-of-band load in the
`endpoint-load-metrics-bin` trailer (base64 `OrcaLoadReport`),
and our clients assert it against both reference servers.
The out-of-band stream itself (`OpenRcaService.StreamCoreMetrics`,
vendored proto with generated stubs) is also graded: our
JS/Go/Python/Rust clients feed the shared state via `FullDuplexCall`
and read it back on the stream, against the reference Go
server's ORCA service and against our own servers. The
real-client runs drive the cases with the upstream Go interop
client through its `test_backend_metrics_load_balancer`
service config; grpc-java's `TestServiceClient` is not used
for them (it fails `orca_per_rpc` even against the upstream
Go interop server — its report capture comes back null).

The grpc-dc frame layer carries response initial and
trailing metadata in every generated runtime (server-side
`ctx.setHeaders`/`setTrailers` in JS, `grpcdc.SetHeader`/
`SetTrailer` in Go, `ctx.set_headers`/`set_trailers` in
Python, and the equivalent context API in the other 13
runtimes; `-bin` values are base64, as on the HTTP/2 wire),
so `custom_metadata` runs in both directions and asserts
the full upstream echo (UnaryCall and FullDuplexCall). The cancel cases run in Direction A under
all three drivers (JS via an `AbortSignal` call option).
`cacheable_unary` runs only in Direction B under the Java
client: the official servers do not implement
CacheableUnaryCall at all (upstream the case needs a caching
proxy), and the Go client lacks the case.
