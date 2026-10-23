<?php
// Dynamic (descriptor-driven) runtime: schemas consumed as data at
// runtime, no generated stubs. Loopback plus the official grpc-java
// oracle in both directions (oracle == runtime test bed).
// Mirrors ruby/tests/test_dynamic.rb.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/dynamic_echo.php";
require_once __DIR__ . "/../examples/stdio.php";
require_once __DIR__ . "/test_util.php";
require_once __DIR__ . "/test_oracle.php";

final class TestDynamic
{
    private const SERVICE = "echo.Echo";

    private static function loadModel(): \Grpcdc\FileModel
    {
        $path = T::root() . "/fixtures/echo_descriptor_set.bin";
        if (!file_exists($path)) {
            T::skip("descriptor fixture missing (make generate)");
        }
        return \Grpcdc\Dyn::parseDescriptorSet(file_get_contents($path));
    }

    private static function request(\Grpcdc\FileModel $model, string $message, int $count = 0): \Grpcdc\GenericMessage
    {
        return (new \Grpcdc\GenericMessage($model->messages[".echo.EchoRequest"]))
            ->set(1, $message)->set(2, $count);
    }

    private static function runScenarios(\Grpcdc\DynamicClient $client, \Grpcdc\FileModel $model): void
    {
        $scenarios = require __DIR__ . "/oracle_scenarios_generated.php";
        foreach ($scenarios as $c) {
            $kind = $c["kind"];
            $messages = array_map(fn($m) => OracleRunner::unmsg($m), $c["messages"]);
            $line = $kind . " " . implode(" ", $c["messages"]);
            switch ($kind) {
                case "UNARY":
                    try {
                        $resp = $client->unary(self::SERVICE, "Unary", self::request($model, $messages[0]));
                    } catch (\Grpcdc\StatusError $e) {
                        if ($c["expect_status"] !== null) {
                            T::assertEq($e->statusCode, $c["expect_status"], $line);
                            continue 2;
                        }
                        throw $e;
                    }
                    T::assertEq($resp->getString(1), "echo: " . $messages[0], $line);
                    T::assertEq($resp->getInt(2), 0, $line);
                    break;
                case "SERVER_STREAM":
                    $responses = iterator_to_array($client->serverStream(self::SERVICE, "ServerStream", self::request($model, $messages[0], $c["count"]))->iterate(), false);
                    T::assertEq(count($responses), $c["count"], $line);
                    foreach ($responses as $i => $resp) {
                        T::assertEq($resp->getString(1), $messages[0], $line);
                        T::assertEq($resp->getInt(2), $i, $line);
                    }
                    break;
                case "CLIENT_STREAM":
                    $resp = $client->clientStream(self::SERVICE, "ClientStream", array_map(fn($m) => self::request($model, $m), $messages));
                    T::assertEq($resp->getString(1), implode("+", $messages), $line);
                    T::assertEq($resp->getInt(2), count($messages), $line);
                    break;
                case "BIDI":
                    $responses = iterator_to_array($client->bidi(self::SERVICE, "Bidi", array_map(fn($m) => self::request($model, $m), $messages))->iterate(), false);
                    T::assertEq(count($responses), count($messages), $line);
                    foreach ($responses as $i => $resp) {
                        T::assertEq($resp->getString(1), $messages[$i], $line);
                        T::assertEq($resp->getInt(2), $i, $line);
                    }
                    break;
                default:
                    throw new \Exception("unknown scenario kind: $kind");
            }
        }
    }

    public static function run(): void
    {
        $root = T::root();
        $model = self::loadModel();

        // Loopback: dynamic client + dynamic server, all shapes.
        [$a, $b] = \Grpcdc\memoryTransportPair();
        $server = new \Grpcdc\Server();
        \Grpcdc\Dyn::registerDynamicService($server, $model, self::SERVICE, new DynamicEchoService());
        $serverEp = $server->serveTransport($b);
        $channel = new \Grpcdc\Channel($a);
        T::wirePeerPumps($channel->endpoint, $serverEp);
        $client = new \Grpcdc\DynamicClient($channel, $model);
        self::runScenarios($client, $model);

        // Generic encode/decode round trip.
        $modelType = $model->messages[".echo.EchoRequest"];
        $req = self::request($model, "hi", 2);
        $decoded = \Grpcdc\Dyn::decodeGeneric($modelType, \Grpcdc\Dyn::encodeGeneric($modelType, $req, $model), $model);
        T::assertEq($decoded->getString(1), "hi", "round trip message");
        T::assertEq($decoded->getInt(2), 2, "round trip count");

        // Unknown fields 99 (varint 42) and 100 (string "x") are
        // retained across a decode -> encode round trip.
        $payload = hex2bin("0a0268691002") . chr(0x98) . chr(0x06) . chr(0x2A) . chr(0xA2) . chr(0x06) . chr(0x01) . "x";
        $decoded = \Grpcdc\Dyn::decodeGeneric($modelType, $payload, $model);
        T::assertEq(count($decoded->unknown), 2, "unknown retained");
        T::assertEq(\Grpcdc\Dyn::encodeGeneric($modelType, $decoded, $model), $payload, "unknown re-emitted");

        // Oracle, both directions.
        $cp = T::javaClasspath($root);

        [$serverProc, $serverPipes, $port] = OracleRunner::startJavaServer($cp);
        try {
            [$bridgeProc, $bridgePipes] = OracleRunner::startBridge(
                ["dc-to-http2", "--grpc", "127.0.0.1:" . $port],
                null
            );
            try {
                $transport = new StdioTransport($bridgePipes[0], $bridgePipes[1]);
                $dynClient = new \Grpcdc\DynamicClient(new \Grpcdc\Channel($transport), $model);
                self::runScenarios($dynClient, $model);
            } finally {
                OracleRunner::kill($bridgeProc);
            }
        } finally {
            OracleRunner::kill($serverProc);
        }

        $port = OracleRunner::freePort();
        $serverCmd = T::phpExe() . " " . $root . "/php/examples/dynamic_echo_server_stdio.php";
        [$bridgeProc, $bridgePipes] = OracleRunner::startBridge(
            ["http2-to-dc", "--port", (string)$port, "--target-cmd", $serverCmd]
        );
        try {
            $proc = proc_open(
                ["java", "-cp", $cp, "dc.oracle.OracleClient", (string)$port, $root . "/fixtures/oracle_scenarios.txt"],
                [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
                $pipes
            );
            fclose($pipes[0]);
            $out = stream_get_contents($pipes[1]);
            $err = stream_get_contents($pipes[2]);
            fclose($pipes[1]);
            fclose($pipes[2]);
            $code = proc_close($proc);
            T::assertEq($code, 0, $out . $err);
            T::assertIncludes($out, "ORACLE CLIENT: ALL OK");
        } finally {
            OracleRunner::kill($bridgeProc);
        }
    }
}
