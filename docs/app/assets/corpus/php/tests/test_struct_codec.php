<?php
// Struct-codec negotiation: struct<->struct roundtrip all four
// shapes, struct client to protobuf server fails UNIMPLEMENTED,
// plain client to struct server succeeds.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

final class TestStructCodec
{
    private static function req(string $message, int $count = 0): \EchoPb\EchoRequest
    {
        return new \EchoPb\EchoRequest($message, $count);
    }

    private static function setup(bool $clientStruct, bool $serverStruct): \EchoGrpcDc\EchoClient
    {
        [$a, $b] = \Grpcdc\memoryTransportPair();
        $server = new \Grpcdc\Server();
        $server->setStructCodec($serverStruct);
        \EchoGrpcDc\registerEchoServer($server, new EchoService());
        $serverEp = $server->serveTransport($b);
        $channel = new \Grpcdc\Channel($a);
        $channel->setStructCodec($clientStruct);
        T::wirePeerPumps($channel->endpoint, $serverEp);
        return new \EchoGrpcDc\EchoClient($channel);
    }

    public static function run(): void
    {
        $client = self::setup(true, true);

        $resp = $client->Unary(self::req("hello"));
        T::assertEq($resp->message, "echo: hello", "struct unary");

        $responses = iterator_to_array($client->ServerStream(self::req("tick", 3))->iterate(), false);
        T::assertEq(array_map(fn($r) => $r->index, $responses), [0, 1, 2], "struct server-stream");

        $resp = $client->ClientStream([self::req("a"), self::req("b")]);
        T::assertEq($resp->message, "a+b", "struct client-stream");

        $responses = iterator_to_array($client->Bidi([self::req("x"), self::req("y")])->iterate(), false);
        T::assertEq(array_map(fn($r) => $r->message, $responses), ["x", "y"], "struct bidi");

        $bytes = self::req("hello")->marshalStruct();
        T::check(str_starts_with($bytes, "DCS1"), "struct magic");
        $back = (new \EchoPb\EchoRequest())->unmarshalStruct($bytes);
        T::assertEq($back->message, "hello", "struct roundtrip");

        $mismatch = self::setup(true, false);
        try {
            $mismatch->Unary(self::req("hello"));
            throw new \Exception("expected StatusError");
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, \Grpcdc\Wire::CODE_UNIMPLEMENTED, "mismatch status");
        }

        $plain = self::setup(false, true);
        $resp = $plain->Unary(self::req("hello"));
        T::assertEq($resp->message, "echo: hello", "plain vs struct server");

        echo "TestStructCodec OK\n";
    }
}
