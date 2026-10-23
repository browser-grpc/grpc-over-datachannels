<?php
// Loopback end-to-end: all four shapes, error status, metadata.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

final class TestEcho
{
    private static function req(string $message, int $count = 0): \EchoPb\EchoRequest
    {
        return new \EchoPb\EchoRequest($message, $count);
    }

    public static function run(): void
    {
        [$a, $b] = \Grpcdc\memoryTransportPair();
        $server = new \Grpcdc\Server();
        \EchoGrpcDc\registerEchoServer($server, new EchoService());
        $serverEp = $server->serveTransport($b);
        $channel = new \Grpcdc\Channel($a);
        T::wirePeerPumps($channel->endpoint, $serverEp);
        $client = new \EchoGrpcDc\EchoClient($channel);

        $resp = $client->Unary(self::req("hello"));
        T::assertEq($resp->message, "echo: hello", "unary message");
        T::assertEq($resp->index, 0, "unary index");

        $responses = iterator_to_array($client->ServerStream(self::req("tick", 3))->iterate(), false);
        T::assertEq(array_map(fn($r) => $r->index, $responses), [0, 1, 2], "server-stream index");
        T::check(count(array_filter($responses, fn($r) => $r->message === "tick")) === 3, "server-stream message");

        $resp = $client->ClientStream([self::req("a"), self::req("b"), self::req("c")]);
        T::assertEq($resp->message, "a+b+c", "client-stream message");
        T::assertEq($resp->index, 3, "client-stream index");

        $responses = iterator_to_array($client->Bidi([self::req("x"), self::req("y")])->iterate(), false);
        T::assertEq(array_map(fn($r) => $r->message, $responses), ["x", "y"], "bidi message");
        T::assertEq(array_map(fn($r) => $r->index, $responses), [0, 1], "bidi index");

        try {
            $client->Unary(self::req("fail"));
            throw new \Exception("expected StatusError");
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, 3, "error status"); // INVALID-ARGUMENT
        }

        $resp = $client->Unary(self::req("hello"), ["x-echo" => "meta"]);
        T::assertEq($resp->message, "echo: hello [meta]", "metadata");
    }
}
