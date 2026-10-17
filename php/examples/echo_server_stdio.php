<?php
// Interop harness: the PHP echo server over stdio. Other
// languages' tests spawn this and drive it with their client.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/echo_grpc_dc.php";
require_once __DIR__ . "/echo_service.php";
require_once __DIR__ . "/stdio.php";

$transport = new StdioTransport(STDOUT, STDIN);
// Exit when the driver closes our stdin.
$transport->onEof = function () {
    exit(0);
};
$server = new \Grpcdc\Server();
\EchoGrpcDc\registerEchoServer($server, new EchoService());
$endpoint = $server->serveTransport($transport);
$server->serveForever($endpoint);
