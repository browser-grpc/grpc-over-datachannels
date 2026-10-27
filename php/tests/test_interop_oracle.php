<?php
// Interop client grading: the generated PHP TestService client
// runs the canonical grpc interop cases (generated table:
// interop_cases_generated.php) against the official grpc-go
// TestServiceServer, through the bridge (dc-to-http2, stdio =
// DataChannel). Skips when the Go server binary is not built
// (Dockerfile.ci builds it).

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/test_grpc_dc.php";
require_once __DIR__ . "/../examples/orca_grpc_dc.php";
require_once __DIR__ . "/../examples/stdio.php";
require_once __DIR__ . "/test_util.php";
require_once __DIR__ . "/test_oracle.php";

final class TestInteropOracle
{
    private const INITIAL_KEY = "x-grpc-test-echo-initial";
    private const INITIAL_VAL = "test_initial_metadata_value";
    private const TRAILER_KEY = "x-grpc-test-echo-trailing-bin";
    // -bin values are base64 on the grpc-dc wire: "q83v" is
    // base64 for the bytes AB CD EF the official case sends.
    private const TRAILER_VAL = "q83v";

    private static function payload(int $size): \MessagesPb\Payload
    {
        return new \MessagesPb\Payload(
            \MessagesPb\PayloadType::COMPRESSABLE, str_repeat("\0", $size));
    }

    private static function outReq(array $respSizes, ?\MessagesPb\EchoStatus $status = null): \MessagesPb\StreamingOutputCallRequest
    {
        $req = new \MessagesPb\StreamingOutputCallRequest();
        $req->responseParameters = array_map(
            fn($s) => new \MessagesPb\ResponseParameters($s), $respSizes);
        $req->responseStatus = $status;
        return $req;
    }

    private static function expectStatus(string $what, int $code, ?string $message, callable $fn): void
    {
        try {
            $fn();
        } catch (\Grpcdc\StatusError $e) {
            T::assertEq($e->statusCode, $code, $what);
            if ($message !== null) {
                T::assertEq($e->statusMessage, $message, $what);
            }
            return;
        }
        T::check(false, "$what: expected status error");
    }

    /** @return int[] */
    private static function recvAll($stream): array
    {
        $sizes = [];
        try {
            while (true) {
                $sizes[] = strlen($stream->recv()->payload->body);
            }
        } catch (\Grpcdc\CallClosed $e) {
            // clean end of stream
        }
        return $sizes;
    }

    private static function runCases(\Grpcdc\Channel $channel, \TestGrpcDc\TestServiceClient $client, \TestGrpcDc\UnimplementedServiceClient $unimpl): void
    {
        $cases = require __DIR__ . "/interop_cases_generated.php";
        foreach ($cases as $c) {
            $what = "interop " . $c["name"];
            switch ($c["kind"]) {
                case "EMPTY":
                    $client->EmptyCall(new \EmptyPb\Empty_());
                    break;
                case "LARGE_UNARY":
                    $req = new \MessagesPb\SimpleRequest();
                    $req->responseType = \MessagesPb\PayloadType::COMPRESSABLE;
                    $req->responseSize = $c["resp_sizes"][0];
                    $req->payload = self::payload($c["req_sizes"][0]);
                    $resp = $client->UnaryCall($req);
                    T::assertEq(strlen($resp->payload->body), $c["resp_sizes"][0], $what);
                    break;
                case "CLIENT_STREAMING":
                    $reqs = array_map(
                        fn($s) => new \MessagesPb\StreamingInputCallRequest(self::payload($s)),
                        $c["req_sizes"]);
                    $resp = $client->StreamingInputCall($reqs);
                    T::assertEq($resp->aggregatedPayloadSize, array_sum($c["req_sizes"]), $what);
                    break;
                case "SERVER_STREAMING":
                    $stream = $client->StreamingOutputCall(self::outReq($c["resp_sizes"]));
                    T::assertEq(self::recvAll($stream), $c["resp_sizes"], $what);
                    $stream->close();
                    break;
                case "PING_PONG":
                    $reqs = [];
                    foreach ($c["req_sizes"] as $i => $s) {
                        $r = self::outReq([$c["resp_sizes"][$i]]);
                        $r->payload = self::payload($s);
                        $reqs[] = $r;
                    }
                    $stream = $client->FullDuplexCall($reqs);
                    T::assertEq(self::recvAll($stream), $c["resp_sizes"], $what);
                    $stream->close();
                    break;
                case "EMPTY_STREAM":
                    $stream = $client->FullDuplexCall([]);
                    try {
                        $stream->recv();
                        T::check(false, "$what: expected EOF");
                    } catch (\Grpcdc\CallClosed $e) {
                        // clean end of stream
                    }
                    $stream->close();
                    break;
                case "CUSTOM_METADATA":
                    $md = [self::INITIAL_KEY => self::INITIAL_VAL,
                           self::TRAILER_KEY => self::TRAILER_VAL];
                    $stream = $client->FullDuplexCall([self::outReq([314159])], $md);
                    $resp = $stream->recv();
                    T::assertEq(strlen($resp->payload->body), 314159, $what);
                    $headers = $stream->headers();
                    T::assertEq($headers[self::INITIAL_KEY] ?? null, self::INITIAL_VAL, $what);
                    try {
                        $stream->recv();
                        T::check(false, "$what: expected EOF");
                    } catch (\Grpcdc\CallClosed $e) {
                        // clean end of stream
                    }
                    $trailers = $stream->trailers();
                    T::assertEq($trailers[self::TRAILER_KEY] ?? null, self::TRAILER_VAL, $what);
                    $stream->close();
                    break;
                case "STATUS_UNARY":
                    $req = new \MessagesPb\SimpleRequest();
                    $req->responseStatus = new \MessagesPb\EchoStatus(
                        $c["status_code"], $c["status_message"]);
                    self::expectStatus($what, $c["status_code"], $c["status_message"],
                        fn() => $client->UnaryCall($req));
                    break;
                case "STATUS_DUPLEX":
                    $req = self::outReq([], new \MessagesPb\EchoStatus(
                        $c["status_code"], $c["status_message"]));
                    $stream = $client->FullDuplexCall([$req]);
                    self::expectStatus($what, $c["status_code"], $c["status_message"],
                        fn() => $stream->recv());
                    $stream->close();
                    break;
                case "SPECIAL_STATUS":
                    $req = new \MessagesPb\SimpleRequest();
                    $req->responseStatus = new \MessagesPb\EchoStatus(
                        $c["status_code"], $c["status_message"]);
                    self::expectStatus($what, $c["status_code"], $c["status_message"],
                        fn() => $client->UnaryCall($req));
                    break;
                case "CANCEL_AFTER_BEGIN":
                    // Begin a client-streaming call and cancel it
                    // before sending any request: the pending recv
                    // must report CANCELLED.
                    $stream = $channel->openStream("/grpc.testing.TestService/StreamingInputCall");
                    $stream->cancel();
                    self::expectStatus($what, $c["status_code"], null,
                        fn() => $stream->recv(new \MessagesPb\StreamingInputCallResponse()));
                    break;
                case "CANCEL_AFTER_FIRST":
                    // Duplex call (no half-close): the server
                    // answers the one request, then waits for more
                    // input, so the cancel deterministically lands
                    // mid-call (same shape as the Python/JS suites).
                    $stream = $channel->openStream("/grpc.testing.TestService/FullDuplexCall");
                    $channel->sendMessage($stream, self::outReq([$c["resp_sizes"][0]]));
                    $resp = $stream->recv(new \MessagesPb\StreamingOutputCallResponse());
                    T::assertEq(strlen($resp->payload->body), $c["resp_sizes"][0], $what);
                    $stream->cancel();
                    self::expectStatus($what, $c["status_code"], null,
                        fn() => $stream->recv(new \MessagesPb\StreamingOutputCallResponse()));
                    break;
                case "TIMEOUT_SLEEPING":
                    $req = new \MessagesPb\StreamingOutputCallRequest();
                    $req->responseParameters = array_map(
                        fn($s) => new \MessagesPb\ResponseParameters($s, 1000000),
                        $c["resp_sizes"]);
                    $req->payload = self::payload(0);
                    self::expectStatus($what, $c["status_code"], null,
                        function () use ($client, $req) {
                            $stream = $client->StreamingOutputCall($req, null, 0.1);
                            while (true) {
                                $stream->recv();
                            }
                        });
                    break;
                case "UNIMPLEMENTED_METHOD":
                    self::expectStatus($what, $c["status_code"], null,
                        fn() => $client->UnimplementedCall(new \EmptyPb\Empty_()));
                    break;
                case "UNIMPLEMENTED_SERVICE":
                    self::expectStatus($what, $c["status_code"], null,
                        fn() => $unimpl->UnimplementedCall(new \EmptyPb\Empty_()));
                    break;
                default:
                    T::check(false, "$what: unknown kind " . $c["kind"]);
            }
            echo "interop case ok: " . $c["name"] . "\n";
        }
    }

    // Compression rows (upstream client_compressed_unary,
    // client_compressed_streaming, server_compressed_unary,
    // server_compressed_streaming): the DataChannel wire is
    // compression-free; the client declares grpc-encoding: gzip
    // and the bridge gzips request messages on the HTTP/2 hop,
    // decompressing responses the same way.
    private static function runCompressionCases(\TestGrpcDc\TestServiceClient $client): void
    {
        $gzip = ["grpc-encoding" => "gzip"];
        $req = new \MessagesPb\SimpleRequest();
        $req->responseSize = 31415;
        $req->payload = self::payload(271828);
        $req->expectCompressed = new \MessagesPb\BoolValue(true);
        $resp = $client->UnaryCall($req, $gzip);
        T::assertEq(strlen($resp->payload->body), 31415, "client_compressed_unary");
        echo "interop case ok: client_compressed_unary\n";

        $sizes = [27182, 8, 1828, 45904];
        $reqs = array_map(function ($s) {
            $r = new \MessagesPb\StreamingInputCallRequest();
            $r->payload = self::payload($s);
            $r->expectCompressed = new \MessagesPb\BoolValue(true);
            return $r;
        }, $sizes);
        $resp = $client->StreamingInputCall($reqs, $gzip);
        T::assertEq($resp->aggregatedPayloadSize, array_sum($sizes), "client_compressed_streaming");
        echo "interop case ok: client_compressed_streaming\n";

        $req = new \MessagesPb\SimpleRequest();
        $req->responseSize = 31415;
        $req->payload = self::payload(271828);
        $req->responseCompressed = new \MessagesPb\BoolValue(true);
        $resp = $client->UnaryCall($req);
        T::assertEq(strlen($resp->payload->body), 31415, "server_compressed_unary");
        echo "interop case ok: server_compressed_unary\n";

        $sizes = [31415, 9, 2653, 58979];
        $req = new \MessagesPb\StreamingOutputCallRequest();
        $req->responseParameters = array_map(
            fn($s) => new \MessagesPb\ResponseParameters($s, 0, new \MessagesPb\BoolValue(true)),
            $sizes);
        $req->payload = self::payload(0);
        $stream = $client->StreamingOutputCall($req);
        foreach ($sizes as $size) {
            $one = $stream->recv();
            T::assertEq(strlen($one->payload->body), $size, "server_compressed_streaming");
        }
        $stream->close();
        echo "interop case ok: server_compressed_streaming\n";
    }

    // ORCA rows (upstream orca_per_rpc / orca_oob): per-RPC the
    // report returns as the serialized OrcaLoadReport in the
    // endpoint-load-metrics-bin trailer (base64 -bin value); OOB
    // the value fed through FullDuplexCall comes back on the
    // OpenRcaService StreamCoreMetrics stream.
    private static function runOrcaCases(\Grpcdc\Channel $channel, \TestGrpcDc\TestServiceClient $client): void
    {
        $req = new \MessagesPb\SimpleRequest();
        $req->orcaPerQueryReport = new \MessagesPb\TestOrcaReport(
            0.8210, 0.5847, ["cost" => 3456.32], ["util" => 0.30499]);
        $stream = $channel->serverStream("/grpc.testing.TestService/UnaryCall", $req);
        $stream->recv(new \MessagesPb\SimpleResponse());
        try {
            $stream->recv(new \MessagesPb\SimpleResponse());
            T::check(false, "orca_per_rpc: expected EOF");
        } catch (\Grpcdc\CallClosed $e) {
            // end of stream: trailers now readable
        }
        $encoded = $stream->trailers["endpoint-load-metrics-bin"] ?? null;
        T::check($encoded !== null, "orca_per_rpc: no endpoint-load-metrics-bin trailer");
        $report = new \OrcaLoadReportPb\OrcaLoadReport();
        $report->unmarshalDc(base64_decode($encoded));
        T::check(
            $report->cpuUtilization === 0.8210 && $report->memUtilization === 0.5847 &&
                ($report->requestCost["cost"] ?? null) === 3456.32 &&
                ($report->utilization["util"] ?? null) === 0.30499,
            "orca_per_rpc: report mismatch");
        $stream->close();
        echo "interop case ok: orca_per_rpc\n";

        $feedReq = new \MessagesPb\StreamingOutputCallRequest();
        $feedReq->orcaOobReport = new \MessagesPb\TestOrcaReport(0.9, 0.85, [], ["util" => 0.5]);
        $feed = $client->FullDuplexCall([$feedReq]);
        try {
            while (true) {
                $feed->recv();
            }
        } catch (\Grpcdc\CallClosed $e) {
            // feed call completed
        }
        $feed->close();
        $orca = new \OrcaGrpcDc\OpenRcaServiceClient($channel);
        $metrics = $orca->StreamCoreMetrics(new \OrcaPb\OrcaLoadReportRequest(), null, 30.0);
        $matched = false;
        for ($i = 0; $i < 30 && !$matched; $i++) {
            $got = $metrics->recv();
            $matched = $got->cpuUtilization === 0.9 && $got->memUtilization === 0.85 &&
                ($got->utilization["util"] ?? null) === 0.5;
        }
        T::check($matched, "orca_oob: no matching OOB report");
        $metrics->close();
        echo "interop case ok: orca_oob\n";
    }

    public static function run(): void
    {
        $root = T::root();
        $serverBin = $root . "/oracle/go-interop/interop-server";
        if (!file_exists($serverBin)) {
            T::skip("go interop server not built");
        }
        $port = OracleRunner::freePort();
        $serverProc = proc_open(
            [$serverBin, "-port", (string)$port],
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $serverPipes
        );
        fclose($serverPipes[0]);
        stream_set_blocking($serverPipes[2], false);
        $ready = false;
        for ($i = 0; $i < 300 && !$ready; $i++) {
            $sock = @fsockopen("127.0.0.1", $port, $errno, $errstr, 2);
            if ($sock !== false) {
                fclose($sock);
                $ready = true;
            } else {
                usleep(100 * 1000);
            }
        }
        if (!$ready) {
            OracleRunner::kill($serverProc);
            T::skip("interop server did not start");
        }
        [$bridgeProc, $bridgePipes] = OracleRunner::startBridge(
            ["dc-to-http2", "--grpc", "127.0.0.1:" . $port], null);
        try {
            $transport = new StdioTransport($bridgePipes[0], $bridgePipes[1]);
            $channel = new \Grpcdc\Channel($transport);
            $client = new \TestGrpcDc\TestServiceClient($channel);
            $unimpl = new \TestGrpcDc\UnimplementedServiceClient($channel);
            self::runCases($channel, $client, $unimpl);
            self::runCompressionCases($client);
            self::runOrcaCases($channel, $client);
        } finally {
            OracleRunner::kill($bridgeProc);
            OracleRunner::kill($serverProc);
        }
        echo "TestInteropOracle OK\n";
    }
}
