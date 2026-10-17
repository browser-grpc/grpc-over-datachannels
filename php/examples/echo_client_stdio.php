<?php
// Interop harness: the PHP echo client over stdio. Prints one line
// per call shape to stderr (stdout carries frames) and exits non-zero
// on any failure. Mirrors ruby/examples/echo_client_stdio.rb.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/echo_grpc_dc.php";
require_once __DIR__ . "/echo_pb.php";
require_once __DIR__ . "/stdio.php";

function req(string $message, int $count = 0): \EchoPb\EchoRequest
{
    return new \EchoPb\EchoRequest($message, $count);
}

$transport = new StdioTransport(STDOUT, STDIN);
$client = new \EchoGrpcDc\EchoClient(new \Grpcdc\Channel($transport));

$unary = $client->Unary(req("hello"));
fwrite(STDERR, "unary=" . $unary->message . "\n");

$ticks = [];
foreach ($client->ServerStream(req("tick", 3))->iterate() as $r) {
    $ticks[] = $r->message . "#" . $r->index;
}
fwrite(STDERR, "server_stream=" . implode(",", $ticks) . "\n");

$joined = $client->ClientStream([req("a"), req("b"), req("c")]);
fwrite(STDERR, "client_stream=" . $joined->message . "\n");

$echoed = [];
foreach ($client->Bidi([req("x"), req("y")])->iterate() as $r) {
    $echoed[] = $r->message;
}
fwrite(STDERR, "bidi=" . implode(",", $echoed) . "\n");

$md = $client->Unary(req("hello", 0), ["x-echo" => "meta"]);
fwrite(STDERR, "metadata=" . $md->message . "\n");

try {
    $client->Unary(new \EchoPb\EchoRequest("slow", 0, 400), null, 0.05);
    fwrite(STDERR, "deadline=no error\n");
} catch (\Grpcdc\StatusError $e) {
    fwrite(STDERR, "deadline=" . $e->statusCode . "\n");
}

try {
    $client->Unary(req("fail"));
    fwrite(STDERR, "error_case=no error\n");
    exit(1);
} catch (\Grpcdc\StatusError $e) {
    fwrite(STDERR, "error_case=" . (string)$e . "\n");
}
