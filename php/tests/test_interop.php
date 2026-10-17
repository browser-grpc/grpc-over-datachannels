<?php
// Interop: PHP runtime against the Go stdio harnesses (cross-
// language wire compatibility). Skips when Go is unavailable.
// Mirrors ruby/tests/test_interop.rb (process pumps are a
// single-threaded stream_select loop — PHP has no threads).

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/../examples/echo_grpc_dc.php";
require_once __DIR__ . "/../examples/echo_pb.php";
require_once __DIR__ . "/../examples/stdio.php";
require_once __DIR__ . "/test_util.php";

final class TestInterop
{
    private static function buildGo(string $out, string $pkg): void
    {
        if (!T::which("go")) {
            T::skip("go not available");
        }
        $proc = proc_open(
            ["go", "build", "-o", $out, $pkg],
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $pipes,
            T::root() . "/go"
        );
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[0]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $code = proc_close($proc);
        if ($code !== 0) {
            T::skip("go build $pkg: $stderr");
        }
    }

    private static function req(string $message, int $count = 0): \EchoPb\EchoRequest
    {
        return new \EchoPb\EchoRequest($message, $count);
    }

    public static function run(): void
    {
        self::phpClientCallsGoServer();
        self::goClientCallsPhpServer();
    }

    private static function phpClientCallsGoServer(): void
    {
        $tmp = sys_get_temp_dir() . "/grpcdc-php-interop-" . getmypid();
        mkdir($tmp, 0777, true);
        $serverBin = $tmp . "/echo_server_stdio";
        self::buildGo($serverBin, "./examples/echo_server_stdio");
        $proc = proc_open(
            [$serverBin],
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $pipes
        );
        try {
            $transport = new StdioTransport($pipes[0], $pipes[1]);
            $client = new \EchoGrpcDc\EchoClient(new \Grpcdc\Channel($transport));

            $unary = $client->Unary(self::req("hello"));
            T::assertEq($unary->message, "echo: hello", "interop unary");

            $ticks = iterator_to_array($client->ServerStream(self::req("tick", 3))->iterate(), false);
            T::assertEq(array_map(fn($r) => $r->index, $ticks), [0, 1, 2], "interop server_stream");

            $joined = $client->ClientStream([self::req("a"), self::req("b"), self::req("c")]);
            T::assertEq($joined->message, "a+b+c", "interop client_stream");

            $echoed = iterator_to_array($client->Bidi([self::req("x"), self::req("y")])->iterate(), false);
            T::assertEq(array_map(fn($r) => $r->message, $echoed), ["x", "y"], "interop bidi");

            try {
                $client->Unary(self::req("fail"));
                throw new \Exception("expected StatusError");
            } catch (\Grpcdc\StatusError $e) {
                T::assertEq($e->statusCode, 3, "interop error status");
            }
        } finally {
            proc_terminate($proc, 9);
            proc_close($proc);
            unlink($serverBin);
            rmdir($tmp);
        }
    }

    private static function goClientCallsPhpServer(): void
    {
        $tmp = sys_get_temp_dir() . "/grpcdc-php-interop2-" . getmypid();
        mkdir($tmp, 0777, true);
        $clientBin = $tmp . "/echo_client_stdio";
        self::buildGo($clientBin, "./examples/echo_client_stdio");
        $root = T::root();
        $server = proc_open(
            [T::phpExe(), $root . "/php/examples/echo_server_stdio.php"],
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $serverPipes
        );
        $client = proc_open(
            [$clientBin],
            [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]],
            $clientPipes
        );
        try {
            stream_set_blocking($clientPipes[1], false);
            stream_set_blocking($serverPipes[1], false);
            $stderr = "";
            $deadline = microtime(true) + 60.0;
            while (true) {
                $status = proc_get_status($client);
                if (!$status["running"]) {
                    break;
                }
                if (microtime(true) > $deadline) {
                    throw new \Exception("go client harness timed out");
                }
                $read = [$clientPipes[1], $serverPipes[1], $clientPipes[2]];
                $write = null;
                $except = null;
                $ready = stream_select($read, $write, $except, 0, 200000);
                if ($ready === false || $ready === 0) {
                    continue;
                }
                foreach ($read as $stream) {
                    $chunk = fread($stream, 65536);
                    if ($chunk === false || $chunk === "") {
                        continue;
                    }
                    if ($stream === $clientPipes[1]) {
                        fwrite($serverPipes[0], $chunk);
                        fflush($serverPipes[0]);
                    } elseif ($stream === $serverPipes[1]) {
                        fwrite($clientPipes[0], $chunk);
                        fflush($clientPipes[0]);
                    } else {
                        $stderr .= $chunk;
                    }
                }
            }
            // Drain remaining client stderr.
            stream_set_blocking($clientPipes[2], false);
            $rest = stream_get_contents($clientPipes[2]);
            if ($rest !== false) {
                $stderr .= $rest;
            }
            T::assertIncludes($stderr, "unary=echo: hello");
            T::assertIncludes($stderr, "server_stream=tick#0,tick#1,tick#2");
            T::assertIncludes($stderr, "client_stream=a+b+c");
            T::assertIncludes($stderr, "bidi=x,y");
        } finally {
            proc_terminate($server, 9);
            proc_terminate($client, 9);
            proc_close($server);
            proc_close($client);
            unlink($clientBin);
            rmdir($tmp);
        }
    }
}
