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
`per_rpc_creds`) needs GCP credentials; compression cases run
bridge-only (compression terminates in the proxy/bridge);
`orca_*` and soak cases are out of scope for this harness.

The grpc-dc frame layer carries response initial and
trailing metadata (server `setHeaders`/`setTrailers` — JS
`ctx.setHeaders`, Go `grpcdc.SetHeader`/`SetTrailer`, Python
`ctx.set_headers`/`set_trailers`; `-bin` values are base64,
as on the HTTP/2 wire), so `custom_metadata` runs in both
directions and asserts the full upstream echo (UnaryCall and
FullDuplexCall). Known gaps: the two cancel cases are
covered by the Go and Python drivers in Direction A; the JS
generated client exposes no per-call cancel handle.
`cacheable_unary` runs only under the Java client (the Go
client lacks that case upstream).
