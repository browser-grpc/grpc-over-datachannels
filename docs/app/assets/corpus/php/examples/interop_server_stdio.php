<?php
// Interop harness: the generated PHP TestService server over
// stdio. Direction-B oracle tests spawn this and drive it with
// the official grpc-java / grpc-go interop clients through the
// bridge (oracle/bridge.mjs http2-to-dc).

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/test_grpc_dc.php";
require_once __DIR__ . "/orca_grpc_dc.php";
require_once __DIR__ . "/interop_service_impl.php";
require_once __DIR__ . "/stdio.php";

$transport = new StdioTransport(STDOUT, STDIN);
// Exit when the driver closes our stdin.
$transport->onEof = function () {
    exit(0);
};
$server = new \Grpcdc\Server();
$impl = new InteropServiceImpl();
\TestGrpcDc\registerTestServiceServer($server, $impl);
\OrcaGrpcDc\registerOpenRcaServiceServer($server, $impl);
$endpoint = $server->serveTransport($transport);
// Inside a dispatch fiber, "pump" means yield to the endpoint
// scheduler (which interleaves the other streams); the main
// serve loop keeps reading frames. Outside a fiber, pump the
// endpoint directly.
$impl->pumpFn = function () use ($endpoint) {
    if (\Fiber::getCurrent() !== null) {
        \Fiber::suspend();
        return true;
    }
    return $endpoint->pump();
};
$server->serveForever($endpoint);
