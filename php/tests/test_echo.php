<?php
// Loopback end-to-end: all four shapes, error status, metadata.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

/**
 * Counting slow producer: one message per Fiber suspend, pumping
 * the endpoint between sends (what "slow" means cooperatively).
 */
final class CountingStreamService extends EchoService
{
    public int $produced = 0;
    public ?\Grpcdc\Endpoint $serverEp = null;

    public function ServerStream(\EchoPb\EchoRequest $req, \EchoGrpcDc\SendStream $stream): void
    {
        for ($i = 0; $i < $req->count; $i++) {
            $this->produced++;
            $stream->send(new \EchoPb\EchoResponse($req->message, $i));
            \Fiber::suspend();
            $this->serverEp->pump();
        }
    }
}

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

        // Breaking a server stream cancels it server-side:
        // abandoning the iterate() generator RSTs the call
        // (generator finally / RecvStream close), and the
        // handler's next send fails CANCELLED instead of
        // streaming into the void. Mirrors js/test/echo.test.js
        // "breaking a server stream cancels it server-side"; the
        // cooperative runtime drives the server endpoint from a
        // Fiber so the counting handler produces one message
        // per drive.
        [$a2, $b2] = \Grpcdc\memoryTransportPair();
        $counting = new CountingStreamService();
        $server2 = new \Grpcdc\Server();
        \EchoGrpcDc\registerEchoServer($server2, $counting);
        $serverEp2 = $server2->serveTransport($b2);
        $counting->serverEp = $serverEp2;
        $channel2 = new \Grpcdc\Channel($a2);
        $serverFiber = new \Fiber(function () use ($serverEp2) {
            while (true) {
                $serverEp2->pump();
                \Fiber::suspend();
            }
        });
        $drive = function () use ($serverFiber) {
            if ($serverFiber->isTerminated()) {
                return false;
            }
            if (!$serverFiber->isStarted()) {
                $serverFiber->start();
            } else {
                $serverFiber->resume();
            }
            return true;
        };
        $a2->peerPump = $drive;
        $b2->peerPump = function () use ($channel2) {
            return $channel2->endpoint->pump();
        };
        $client2 = new \EchoGrpcDc\EchoClient($channel2);

        $stream = $client2->ServerStream(self::req("tick", 1000));
        $gen = $stream->iterate();
        $seen = 0;
        foreach ($gen as $resp) {
            $seen++;
            if ($seen === 2) {
                break;
            }
        }
        T::assertEq($seen, 2, "stream break seen");
        unset($gen, $stream);
        gc_collect_cycles();
        for ($i = 0; $i < 4; $i++) {
            $drive();
        }
        $settled = $counting->produced;
        for ($i = 0; $i < 4; $i++) {
            $drive();
        }
        T::assertEq($counting->produced, $settled, "stream break settled");
        T::check($settled < 100, "server kept producing ($settled)");
    }
}
