<?php
// Oracle tests: the official grpc-java implementation, bridged over
// TCP<->DataChannel by ../../oracle/bridge.mjs, must agree with the
// PHP runtime on every case of the generated scenario table
// (oracle_scenarios_generated.php, stamped from racket/oracle-spec.rkt).
// Skips when the Java oracle or Node bridge are unavailable
// (Dockerfile.ci provides both). Mirrors ruby/tests/test_oracle.rb.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/stdio.php";
require_once __DIR__ . "/test_util.php";

final class OracleRunner
{
    public static function unmsg(string $token): string
    {
        return $token === "-" ? "" : $token;
    }

    private static function req(string $message, int $count = 0): \EchoPb\EchoRequest
    {
        return new \EchoPb\EchoRequest($message, $count);
    }

    /** Run the generated scenario table against a static EchoClient. */
    public static function runScenarios(\EchoGrpcDc\EchoClient $client): void
    {
        $scenarios = require __DIR__ . "/oracle_scenarios_generated.php";
        foreach ($scenarios as $c) {
            $kind = $c["kind"];
            $messages = array_map(fn($m) => self::unmsg($m), $c["messages"]);
            $line = $kind . " " . implode(" ", $c["messages"]);
            switch ($kind) {
                case "UNARY":
                    $message = $messages[0];
                    try {
                        $resp = $client->Unary(self::req($message));
                    } catch (\Grpcdc\StatusError $e) {
                        if ($c["expect_status"] !== null) {
                            T::assertEq($e->statusCode, $c["expect_status"], $line);
                            continue 2;
                        }
                        throw $e;
                    }
                    T::assertEq($resp->message, "echo: " . $message, $line);
                    T::assertEq($resp->index, 0, $line);
                    break;
                case "SERVER_STREAM":
                    $message = $messages[0];
                    $responses = iterator_to_array($client->ServerStream(self::req($message, $c["count"]))->iterate(), false);
                    T::assertEq(count($responses), $c["count"], $line);
                    foreach ($responses as $i => $resp) {
                        T::assertEq($resp->message, $message, $line);
                        T::assertEq($resp->index, $i, $line);
                    }
                    break;
                case "CLIENT_STREAM":
                    $resp = $client->ClientStream(array_map(fn($m) => self::req($m), $messages));
                    T::assertEq($resp->message, implode("+", $messages), $line);
                    T::assertEq($resp->index, count($messages), $line);
                    break;
                case "BIDI":
                    $responses = iterator_to_array($client->Bidi(array_map(fn($m) => self::req($m), $messages))->iterate(), false);
                    T::assertEq(count($responses), count($messages), $line);
                    foreach ($responses as $i => $resp) {
                        T::assertEq($resp->message, $messages[$i], $line);
                        T::assertEq($resp->index, $i, $line);
                    }
                    break;
                default:
                    throw new \Exception("unknown scenario kind: $kind");
            }
        }
    }

    public static function freePort(): int
    {
        $sock = stream_socket_server("tcp://127.0.0.1:0", $errno, $errstr);
        if ($sock === false) {
            throw new \Exception("no free port: $errstr");
        }
        $name = stream_socket_get_name($sock, false);
        fclose($sock);
        return (int)substr($name, strrpos($name, ":") + 1);
    }

    /** Spawn the Java oracle server; returns [proc, pipes, port]. */
    public static function startJavaServer(string $cp): array
    {
        $port = self::freePort();
        $proc = proc_open(
            ["java", "-cp", $cp, "dc.oracle.OracleServer", (string)$port],
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $pipes
        );
        fclose($pipes[0]);
        $ready = false;
        while (($line = fgets($pipes[2])) !== false) {
            if (str_contains($line, "READY")) {
                $ready = true;
                break;
            }
        }
        if (!$ready) {
            proc_terminate($proc, 9);
            proc_close($proc);
            T::skip("java oracle server did not start");
        }
        return [$proc, $pipes, $port];
    }

    /** Spawn the Node bridge; returns [proc, pipes]. */
    public static function startBridge(array $args, ?string $expect = "listening"): array
    {
        $cmd = array_merge(["node", T::root() . "/oracle/bridge.mjs"], $args);
        $proc = proc_open(
            $cmd,
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $pipes
        );
        if ($expect !== null) {
            $line = fgets($pipes[2]);
            if ($line === false || !str_contains($line, $expect)) {
                proc_terminate($proc, 9);
                proc_close($proc);
                T::skip("bridge did not start: " . var_export($line, true));
            }
        }
        return [$proc, $pipes];
    }

    public static function kill($proc): void
    {
        if (is_resource($proc)) {
            proc_terminate($proc, 9);
            proc_close($proc);
        }
    }
}

final class TestOracle
{
    public static function run(): void
    {
        $root = T::root();
        $cp = T::javaClasspath($root);

        // PHP client -> official server.
        [$serverProc, $serverPipes, $port] = OracleRunner::startJavaServer($cp);
        try {
            [$bridgeProc, $bridgePipes] = OracleRunner::startBridge(
                ["dc-to-http2", "--grpc", "127.0.0.1:" . $port],
                null
            );
            try {
                $transport = new StdioTransport($bridgePipes[0], $bridgePipes[1]);
                $client = new \EchoGrpcDc\EchoClient(new \Grpcdc\Channel($transport));
                OracleRunner::runScenarios($client);
            } finally {
                OracleRunner::kill($bridgeProc);
            }
        } finally {
            OracleRunner::kill($serverProc);
        }

        // Official client -> PHP server.
        $port = OracleRunner::freePort();
        $serverCmd = T::phpExe() . " " . $root . "/php/examples/echo_server_stdio.php";
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
