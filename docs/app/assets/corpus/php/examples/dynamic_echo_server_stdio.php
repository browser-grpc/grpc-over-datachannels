<?php
// Interop harness: the dynamic (descriptor-driven) PHP echo
// server over stdio. Loads fixtures/echo_descriptor_set.bin at
// runtime — no generated stubs involved. Used by the oracle tests.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/dynamic_echo.php";
require_once __DIR__ . "/stdio.php";

$root = dirname(__DIR__, 2);
$model = \Grpcdc\Dyn::parseDescriptorSet(file_get_contents($root . "/fixtures/echo_descriptor_set.bin"));
$transport = new StdioTransport(STDOUT, STDIN);
$transport->onEof = function () {
    exit(0);
};
$server = new \Grpcdc\Server();
\Grpcdc\Dyn::registerDynamicService($server, $model, "echo.Echo", new DynamicEchoService());
$endpoint = $server->serveTransport($transport);
$server->serveForever($endpoint);
