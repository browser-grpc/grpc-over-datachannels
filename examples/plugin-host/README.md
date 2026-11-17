# Host/plugin example: one public endpoint, out-of-process plugins

A long-lived Rust host serves clients on one endpoint while a
Node plugin process provides the actual Echo service behind it.
Clients only ever dial the host: they discover services through
the Registry, then call Echo, which the host routes DC-to-DC to
the plugin over a Unix domain socket.

This is the reference shape for GitHub issue #2 (host/plugin
support). The four pieces:

| Piece | Where |
|---|---|
| IPC transport (UDS, length-prefixed) | `grpc_dc::uds_dc` / `uds_dc_accept` (Rust), `grpc-dc/stdio` (JS), `grpcdc.DialUds` (Go) |
| Runtime registration | `Server::serve_handle` + `register_service`/`unregister_service` (Rust), `addService`/`removeService` (JS), `RegisterService`/`UnregisterService` (Go) |
| Interceptors | `Endpoint::add_interceptor` (Rust), `Server.addInterceptor` (JS), `Server.AddInterceptor` (Go); rendezvous auth is the built-in first one |
| Discovery + routing | `grpcdc.registry.v1.Registry` (ListServices/GetDescriptor), `route_prefix` (DC-to-DC forwarding by path prefix) |

Run it (three processes):

```sh
cargo build --features webrtc --example plugin_host   # in rust/
mkdir -p /tmp/plugdemo
PLUGIN_DIR=/tmp/plugdemo ./rust/target/debug/examples/plugin_host serve &
node examples/plugin-host/plugin.mjs /tmp/plugdemo &
PLUGIN_DIR=/tmp/plugdemo ./rust/target/debug/examples/plugin_host client
# services: Str("echo.Echo"), Str("grpcdc.registry.v1.Registry")
# echo: echo: from-host-client (from plugin)
```

The client lists services through the Registry (the host answers
from live registrations plus the descriptor store), fetches
descriptors with GetDescriptor when it needs to call dynamically,
and calls Echo — served by the Node plugin, routed by the host.

Plugin lifecycle (spawn, health, restart) is deliberately the host
application's job; this example shows the transport, registry,
and routing seams it builds on.
