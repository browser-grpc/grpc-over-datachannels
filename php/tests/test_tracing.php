<?php
// Tracing: nested callee call joins the trace via the bound channel.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/echo_service.php";
require_once __DIR__ . "/test_util.php";

use Grpcdc\CallContext;
use Grpcdc\Channel;
use Grpcdc\Server;
use Grpcdc\Status;

class TracingRecorder
{
    /** @var array<int, array{string,string,string,string}> */
    public array $starts = [];
    /** @var float[] */
    public array $endDurations = [];

    public function onStart(string $kind, string $method, string $traceId, string $spanId, string $parentSpanId): void
    {
        $this->starts[] = [$kind, $traceId, $spanId, $parentSpanId];
    }

    public function onEnd(string $kind, string $method, string $traceId, string $spanId, string $status, float $durationMs): void
    {
        $this->endDurations[] = $durationMs;
    }
}

class TracingFront extends EchoService
{
    public ?string $seenSpan = null;

    public function __construct(private Channel $downstreamChannel)
    {
    }

    public function Unary(CallContext $ctx, \EchoPb\EchoRequest $req): \EchoPb\EchoResponse
    {
        $this->seenSpan = $ctx->traceContext["span_id"] ?? null;
        $bound = new \EchoGrpcDc\EchoClient(
            $this->downstreamChannel->withTraceContext($ctx->traceContext));
        return $bound->Unary(new \EchoPb\EchoRequest("nested", 0));
    }
}

class TestTracing
{
    public static function run(): void
    {
        $rec = new TracingRecorder();
        Status::setTracer($rec);
        try {
            [$a2, $b2] = \Grpcdc\memoryTransportPair();
            $back = new Server();
            \EchoGrpcDc\registerEchoServer($back, new EchoService());
            $backEp = $back->serveTransport($b2);
            $downstreamChannel = new Channel($a2);
            T::wirePeerPumps($downstreamChannel->endpoint, $backEp);

            $front = new TracingFront($downstreamChannel);
            [$a, $b] = \Grpcdc\memoryTransportPair();
            $frontServer = new Server();
            \EchoGrpcDc\registerEchoServer($frontServer, $front);
            $frontEp = $frontServer->serveTransport($b);
            $clientChannel = new Channel($a);
            T::wirePeerPumps($clientChannel->endpoint, $frontEp);
            $client = new \EchoGrpcDc\EchoClient($clientChannel);

            $resp = $client->Unary(new \EchoPb\EchoRequest("hello", 0));
            T::check($resp->message === "echo: nested", "resp {$resp->message}");

            $starts = $rec->starts;
            T::check(count($starts) === 4, "starts " . count($starts));
            T::check(array_column($starts, 0) === ["client", "server", "client", "server"], "kinds");
            T::check(count(array_unique(array_column($starts, 1))) === 1, "trace ids");
            T::check($starts[1][3] === $starts[0][2], "server parent");
            T::check($starts[2][3] === $starts[1][2], "inner client parent");
            T::check($starts[3][3] === $starts[2][2], "inner server parent");
            T::check($front->seenSpan === $starts[1][2], "ctx span");
            T::check(count($rec->endDurations) === 4, "ends");
            foreach ($rec->endDurations as $d) {
                T::check($d >= 0, "durations");
            }
            echo "TestTracing OK\n";
        } finally {
            Status::setTracer(null);
        }
    }
}
