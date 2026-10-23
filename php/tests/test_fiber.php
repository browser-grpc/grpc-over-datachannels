<?php
// Fiber surface: FiberChannel + generated EchoClientFiber over loopback.
//
// Covers all four shapes, fiber-producer streams pulled one message
// at a time (next), error status, and cancellation not poisoning
// the channel. Mirrors ruby/tests/test_fiber.rb (PHP Fibers throw
// CallClosed at end instead of Ruby's StopIteration).

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

final class TestFiber
{
    private static function req(string $message, int $count = 0): \EchoPb\EchoRequest
    {
        return new \EchoPb\EchoRequest($message, $count);
    }

    private static function clientPair(): array
    {
        [$a, $b] = \Grpcdc\memoryTransportPair();
        $server = new \Grpcdc\Server();
        \EchoGrpcDc\registerEchoServer($server, new EchoService());
        $serverEp = $server->serveTransport($b);
        $channel = new \Grpcdc\Channel($a);
        T::wirePeerPumps($channel->endpoint, $serverEp);
        return [$channel, $a, $b];
    }

    public static function run(): void
    {
        [$channel] = self::clientPair();
        $client = new \EchoGrpcDc\EchoClientFiber(new \Grpcdc\FiberChannel($channel));

        $resp = $client->Unary(self::req("hello"));
        T::assertEq($resp->message, "echo: hello", "fiber unary message");
        T::assertEq($resp->index, 0, "fiber unary index");

        $stream = $client->ServerStream(self::req("tick", 3));
        T::assertEq($stream->next()->index, 0, "fiber next 0");
        T::assertEq($stream->next()->index, 1, "fiber next 1");
        T::assertEq($stream->next()->index, 2, "fiber next 2");
        try {
            $stream->next();
            throw new \Exception("expected CallClosed");
        } catch (\Grpcdc\CallClosed $e) {
            // expected
        }

        $responses = iterator_to_array($client->ServerStream(self::req("tick", 2))->iterate(), false);
        T::assertEq(array_map(fn($r) => $r->index, $responses), [0, 1], "fiber each index");

        $resp = $client->ClientStream([self::req("a"), self::req("b"), self::req("c")]);
        T::assertEq($resp->message, "a+b+c", "fiber client-stream");

        $responses = iterator_to_array($client->Bidi([self::req("x"), self::req("y")])->iterate(), false);
        T::assertEq(array_map(fn($r) => $r->message, $responses), ["x", "y"], "fiber bidi");

        try {
            $client->Unary(self::req("fail"));
            throw new \Exception("expected StatusError");
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, 3, "fiber error status");
        }

        // Wrap a plain sync Channel instead of a FiberChannel.
        [$channel2] = self::clientPair();
        $wrapped = new \EchoGrpcDc\EchoClientFiber($channel2);
        T::assertEq($wrapped->Unary(self::req("wrapped"))->message, "echo: wrapped", "fiber wrapped channel");

        // Cancellation: a long stream is aborted; the fiber sees the
        // cancellation status and the channel stays usable.
        $stream = $client->ServerStream(self::req("tick", 100000));
        T::assertEq($stream->next()->index, 0, "cancel first");
        $stream->cancel();
        try {
            while (true) {
                $stream->next();
            }
            throw new \Exception("expected cancellation");
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, 1, "cancel status"); // CANCELLED
        }
        $resp = $client->Unary(self::req("after"));
        T::assertEq($resp->message, "echo: after", "fiber after cancel");
    }
}
