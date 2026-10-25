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

- `js/test/interop_oracle.test.js`
- `python/tests/test_interop_oracle.py`
- `go/interop_oracle_test.go`

Excluded cases: auth (`*_creds`, `oauth2_auth_token`,
`per_rpc_creds`) needs GCP credentials; compression cases run
bridge-only (compression terminates in the proxy/bridge);
`orca_*` and soak cases are out of scope for this harness.

Known gaps: `custom_metadata` asserts the initial-metadata
echo (Python) — response trailing metadata is not surfaced by
the grpc-dc frame layer (TRAILERS carries status only). The
two cancel cases are covered by the Go and Python drivers;
the JS generated client exposes no per-call cancel handle.
