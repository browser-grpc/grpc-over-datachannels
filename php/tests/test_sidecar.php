<?php
// gRPC over WebRTC-Direct via the Rust sidecar, PHP to PHP.
// Two modes:
//   php test_sidecar.php serve <port>  -- server subprocess
//   TestSidecar::run()                 -- client test (main.php)
// The server runs in its own process because this runtime is
// cooperative: its sidecar socket reads block, which is exactly
// what serveForever wants. The client drives its calls against
// the second sidecar.

require_once __DIR__ . "/test_util.php";

final class TestSidecar
{
    private static function root(): string
    {
        return dirname(__DIR__, 2);
    }

    private static function sidecar(): string
    {
        $bin = self::root() . "/webrtc/rust/target/debug/examples/direct_sidecar";
        if (!is_executable($bin)) {
            $cmd = "cargo build --example direct_sidecar --manifest-path "
                . escapeshellarg(self::root() . "/webrtc/rust/Cargo.toml") . " 2>/dev/null";
            exec($cmd, $_, $code);
            if ($code !== 0) {
                throw new Exception("cargo build direct_sidecar failed");
            }
        }
        return $bin;
    }

    private static function freePort(): int
    {
        $s = stream_socket_server("tcp://127.0.0.1:0");
        $name = stream_socket_get_name($s, false);
        fclose($s);
        return (int) substr($name, strrpos($name, ":") + 1);
    }

    /** @param resource $proc */
    private static function readLine($proc, string $needle): string
    {
        $deadline = microtime(true) + 30;
        while (microtime(true) < $deadline) {
            $line = fgets($proc);
            if ($line === false) {
                throw new Exception("sidecar exited");
            }
            if (str_contains($line, $needle)) {
                return trim($line);
            }
        }
        throw new Exception("sidecar did not print {$needle}");
    }

    /** Server subprocess entry: serve Echo on one sidecar TCP conn. */
    public static function serve(string $port): void
    {
        require_once dirname(__DIR__) . "/grpcdc.php";
        require_once dirname(__DIR__) . "/examples/echo_grpc_dc.php";
        require_once dirname(__DIR__) . "/examples/echo_pb.php";
        require_once dirname(__DIR__) . "/examples/echo_service.php";

        $listener = stream_socket_server("tcp://127.0.0.1:{$port}");
        $conn = stream_socket_accept($listener);
        $server = new \Grpcdc\Server();
        \EchoGrpcDc\registerEchoServer($server, new EchoService());
        $endpoint = $server->serveTransport(new \Grpcdc\SidecarTransport($conn));
        $server->serveForever($endpoint);
    }

    public static function run(): void
    {
        require_once dirname(__DIR__) . "/grpcdc.php";
        require_once dirname(__DIR__) . "/examples/echo_grpc_dc.php";
        require_once dirname(__DIR__) . "/examples/echo_pb.php";

        $bin = self::sidecar();
        $langPort = self::freePort();
        $serverProc = proc_open(
            [PHP_BINARY, __FILE__, "serve", (string) $langPort],
            [["pipe", "r"], ["file", "/dev/null", "a"], ["file", "/dev/null", "a"]],
            $serverPipes
        );

        $listen = proc_open(
            [$bin, "listen", "--udp", "127.0.0.1:0", "--tcp", "127.0.0.1:{$langPort}"],
            [["pipe", "r"], ["pipe", "w"], ["file", "/dev/null", "a"]],
            $listenPipes
        );
        $multiaddr = explode(" ", self::readLine($listenPipes[1], "MULTIADDR"), 2)[1];
        T::check(str_contains($multiaddr, "/webrtc-direct/certhash/f"), "multiaddr: {$multiaddr}");

        $clientPort = self::freePort();
        $dial = proc_open(
            [$bin, "dial", "--multiaddr", $multiaddr, "--tcp", "127.0.0.1:{$clientPort}"],
            [["pipe", "r"], ["pipe", "w"], ["file", "/dev/null", "a"]],
            $dialPipes
        );
        self::readLine($dialPipes[1], "TCP");

        try {
            $client = new \EchoGrpcDc\EchoClient(
                new \Grpcdc\Channel(\Grpcdc\SidecarTransport::connect("127.0.0.1", $clientPort))
            );
            $resp = $client->Unary(new \EchoPb\EchoRequest("hello", 0));
            T::assertEq($resp->message, "echo: hello", "sidecar unary message");
            $indexes = [];
            foreach ($client->ServerStream(new \EchoPb\EchoRequest("tick", 3))->iterate() as $r) {
                $indexes[] = $r->index;
            }
            T::assertEq($indexes, [0, 1, 2], "sidecar stream indexes");
            echo "TestSidecar OK\n";
        } finally {
            proc_terminate($dial);
            proc_terminate($listen);
            proc_terminate($serverProc);
        }
    }
}

// Subprocess entry (not via main.php).
if (PHP_SAPI === "cli" && realpath($_SERVER["SCRIPT_FILENAME"] ?? "") === __FILE__
    && ($_SERVER["argv"][1] ?? "") === "serve") {
    TestSidecar::serve($_SERVER["argv"][2]);
}
