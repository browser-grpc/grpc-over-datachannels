<?php
// BDD: interprets the generated behavior scenarios.
//
// bdd_scenarios_generated.php is generated from the BDD specification;
// the prose lives in BDD.md. The scenarios run against a loopback
// client+server — they are the executable examples, so documentation
// cannot drift from behavior.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

/**
 * Counting slow producer for the stream-break scenario: one
 * message per Fiber suspend, pumping the endpoint between sends
 * (what "slow" means cooperatively). Mirrors test_echo.php.
 */
final class TestBddCountingStreamService extends EchoService
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

final class TestBdd
{
    private static \EchoGrpcDc\EchoClient $client;
    private static \Grpcdc\Channel $channel;

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
        self::$channel = new \Grpcdc\Channel($a);
        T::wirePeerPumps(self::$channel->endpoint, $serverEp);
        self::$client = new \EchoGrpcDc\EchoClient(self::$channel);

        $scenarios = require __DIR__ . "/bdd_scenarios_generated.php";
        foreach ($scenarios as $row) {
            [$name, $kind, $messages, $count, $path, $metadata, $expectMessage, $expectNum, $expectStatus] = $row;
            try {
                self::runScenario($kind, $messages, $count, $path, $metadata, $expectMessage, $expectNum, $expectStatus);
            } catch (\Throwable $e) {
                throw new \Exception("scenario $name: " . get_class($e) . ": " . $e->getMessage());
            }
        }
    }

    private static function runScenario(string $kind, array $messages, int $count, string $path, string $metadata, string $expectMessage, int $expectNum, int $expectStatus): void
    {
        switch ($kind) {
            case "unary-trailer":
                $stream = self::$channel->serverStream("/echo.Echo/Unary", self::req($messages[0]),
                                                       ["x-echo-trailer" => $metadata]);
                $resp = $stream->recv(new \EchoPb\EchoResponse());
                T::assertEq($resp->message, $expectMessage, "trailer message");
                T::assertEq($resp->index, $expectNum, "trailer index");
                try {
                    $stream->recv(new \EchoPb\EchoResponse());
                    throw new \Exception("expected CallClosed");
                } catch (\Grpcdc\CallClosed $e) {
                    // expected: trailers end the stream
                }
                T::assertEq($stream->trailers["x-echo-trailer"] ?? null, $metadata, "trailer");
                break;
            case "unary":
                $md = ($metadata !== "" ) ? ["x-echo" => $metadata] : null;
                if ($expectStatus >= 0) {
                    try {
                        self::$client->Unary(self::req($messages[0]), $md);
                        throw new \Exception("expected StatusError");
                    } catch (\Grpcdc\StatusError $e) {
                        T::assertEq($e->statusCode, $expectStatus, "unary status");
                    }
                } else {
                    $resp = self::$client->Unary(self::req($messages[0]), $md);
                    T::assertEq($resp->message, $expectMessage, "unary message");
                    T::assertEq($resp->index, $expectNum, "unary index");
                }
                break;
            case "server-stream":
                $responses = iterator_to_array(self::$client->ServerStream(self::req($messages[0], $count))->iterate(), false);
                T::assertEq(count($responses), $expectNum, "server-stream count");
                foreach ($responses as $i => $resp) {
                    T::assertEq($resp->message, $expectMessage, "server-stream message");
                    T::assertEq($resp->index, $i, "server-stream index");
                }
                break;
            case "client-stream":
                $resp = self::$client->ClientStream(array_map(fn($m) => self::req($m), $messages));
                T::assertEq($resp->message, $expectMessage, "client-stream message");
                T::assertEq($resp->index, $expectNum, "client-stream index");
                break;
            case "bidi":
                $responses = iterator_to_array(self::$client->Bidi(array_map(fn($m) => self::req($m), $messages))->iterate(), false);
                T::assertEq(count($responses), $expectNum, "bidi count");
                foreach ($responses as $i => $resp) {
                    T::assertEq($resp->message, $messages[$i], "bidi message");
                    T::assertEq($resp->index, $i, "bidi index");
                }
                break;
            case "server-stream-fail":
                try {
                    iterator_to_array(self::$client->ServerStream(self::req($messages[0], $count))->iterate(), false);
                    throw new \Exception("expected StatusError");
                } catch (\Grpcdc\StatusError $e) {
                    T::assertEq($e->statusCode, $expectStatus, "server-stream-fail status");
                }
                break;
            case "bidi-fail":
                try {
                    iterator_to_array(self::$client->Bidi(array_map(fn($m) => self::req($m), $messages))->iterate(), false);
                    throw new \Exception("expected StatusError");
                } catch (\Grpcdc\StatusError $e) {
                    T::assertEq($e->statusCode, $expectStatus, "bidi-fail status");
                }
                break;
            case "deadline":
                try {
                    self::$client->Unary(new \EchoPb\EchoRequest($messages[0], 0, $count), null, 0.1);
                    throw new \Exception("expected StatusError");
                } catch (\Grpcdc\StatusError $e) {
                    T::assertEq($e->statusCode, $expectStatus, "deadline status");
                }
                break;
            case "cancel":
                $stream = self::$channel->serverStream("/echo.Echo/ServerStream", self::req($messages[0], $count));
                $first = new \EchoPb\EchoResponse();
                $stream->recv($first);
                T::assertEq($first->message, $messages[0], "cancel first");
                $stream->cancel();
                $terminated = false;
                try {
                    for ($i = 0; $i < $count + 2; $i++) {
                        $stream->recv(new \EchoPb\EchoResponse());
                    }
                } catch (\Throwable $e) {
                    $terminated = true;
                }
                T::assertEq($terminated, true, "cancel terminated");
                break;
            case "stream-break":
                // Dedicated counting server (mirrors test_echo.php):
                // breaking the foreach abandons the iterate()
                // generator; dropping it and the stream (generator
                // finally / RecvStream __destruct) RSTs the call —
                // no explicit cancel. "Waiting" drives the server
                // Fiber, as the cooperative runtime does elsewhere.
                [$a2, $b2] = \Grpcdc\memoryTransportPair();
                $counting = new TestBddCountingStreamService();
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
                $stream = $client2->ServerStream(self::req($messages[0], $count));
                $gen = $stream->iterate();
                $seen = 0;
                foreach ($gen as $resp) {
                    T::assertEq($resp->message, $messages[0], "stream-break first");
                    T::assertEq($resp->index, 0, "stream-break first index");
                    $seen++;
                    if ($seen === 1) {
                        break;
                    }
                }
                T::assertEq($seen, 1, "stream-break seen");
                unset($gen, $stream);
                gc_collect_cycles();
                for ($i = 0; $i < 4; $i++) {
                    $drive();
                }
                $settled = $counting->produced;
                for ($i = 0; $i < 4; $i++) {
                    $drive();
                }
                T::assertEq($counting->produced, $settled, "stream-break settled");
                T::check($settled < 50, "server kept producing ($settled)");
                break;
            case "raw-unary":
                try {
                    self::$channel->unary($path, self::req($messages[0]), new \EchoPb\EchoResponse());
                    throw new \Exception("expected StatusError");
                } catch (\Grpcdc\StatusError $e) {
                    T::assertEq($e->statusCode, $expectStatus, "raw-unary status");
                }
                break;
            default:
                throw new \Exception("unknown bdd kind: $kind");
        }
    }
}
