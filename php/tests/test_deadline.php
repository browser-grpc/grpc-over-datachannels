<?php
// Deadlines: grpc-timeout propagation + DEADLINE_EXCEEDED in the
// cooperative pump loop. A delaying transport wrapper holds back
// inbound messages so a deadline can fire deterministically in
// the single-threaded model (mirrors lua/tests/test_deadline.lua);
// the ctx budget is checked on the server.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

class DeadlineSlowEcho extends EchoService
{
    public ?\Grpcdc\CallContext $seenCtx = null;

    public function Unary(\Grpcdc\CallContext $ctx, \EchoPb\EchoRequest $req): \EchoPb\EchoResponse
    {
        $this->seenCtx = $ctx;
        return parent::Unary($ctx, $req);
    }
}

/** Holds back inbound messages until a wall-clock release time. */
class HoldTransport extends \Grpcdc\Transport
{
    private \Grpcdc\Transport $inner;
    public float $releaseAt = 0.0;

    public function __construct(\Grpcdc\Transport $inner)
    {
        $this->inner = $inner;
    }

    public function send(string $data): void
    {
        $this->inner->send($data);
    }

    public function recvMessage(): ?string
    {
        if (microtime(true) < $this->releaseAt) {
            return null;
        }
        return $this->inner->recvMessage();
    }

    public function close(): void
    {
        $this->inner->close();
    }
}

final class TestDeadline
{
    private static function req(string $message, int $count = 0): \EchoPb\EchoRequest
    {
        return new \EchoPb\EchoRequest($message, $count);
    }

    public static function run(): void
    {
        T::assertEq(\Grpcdc\Codec::parseTimeout(\Grpcdc\Codec::encodeTimeout(0.25)), 0.25, "timeout round trip");
        T::assertEq(\Grpcdc\Codec::parseTimeout("10x"), null, "junk timeout");

        [$a, $b] = \Grpcdc\memoryTransportPair();
        $hold = new HoldTransport($a);
        // peerPump lives on the outer transport the endpoint sees:
        // Endpoint consults $transport->peerPump on $hold, and the
        // server endpoint pumps from $b with no hold.
        $server = new \Grpcdc\Server();
        $slow = new DeadlineSlowEcho();
        \EchoGrpcDc\registerEchoServer($server, $slow);
        $serverEp = $server->serveTransport($b);
        $channel = new \Grpcdc\Channel($hold);
        $hold->peerPump = function () use ($serverEp) {
            return $serverEp->pump();
        };
        $b->peerPump = function () use ($channel) {
            return $channel->endpoint->pump();
        };
        $client = new \EchoGrpcDc\EchoClient($channel);

        $hold->releaseAt = microtime(true) + 0.4;
        $start = microtime(true);
        try {
            $client->Unary(self::req("hello"), null, 0.05);
            throw new \Exception("expected deadline");
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, 4, "deadline code");
        }
        T::check(microtime(true) - $start < 0.35, "deadline fires fast");

        T::check($slow->seenCtx !== null, "handler ran");
        T::check(isset($slow->seenCtx->metadata["grpc-timeout"]), "grpc-timeout metadata");
        T::check($slow->seenCtx->deadline !== null, "ctx deadline");
        T::check($slow->seenCtx->timeRemaining() !== null, "ctx remaining");

        // After the hold lapses, a generous deadline succeeds.
        while (microtime(true) < $hold->releaseAt) {
            // busy-wait for the hold to lapse (single-threaded test)
        }
        $joined = $client->ClientStream([self::req("a"), self::req("b")], null, 5.0);
        T::assertEq($joined->message, "a+b", "generous timeout");

        // Fiber client carries the same behavior.
        $hold->releaseAt = microtime(true) + 0.4;
        $fiberClient = new \EchoGrpcDc\EchoClientFiber(new \Grpcdc\FiberChannel($channel));
        try {
            $fiberClient->Unary(self::req("hello"), null, 0.05);
            throw new \Exception("expected fiber deadline");
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, 4, "fiber code");
        }
    }
}
