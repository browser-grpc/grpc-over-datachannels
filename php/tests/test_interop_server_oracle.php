<?php
// Interop oracle, Direction B: the OFFICIAL interop clients
// (grpc-java TestServiceClient, grpc-go interop-client) run the
// canonical cases against the generated PHP TestService server
// (examples/interop_server_stdio.php), reached over HTTP/2
// through oracle/bridge.mjs http2-to-dc. Skips when an oracle
// binary or Node is unavailable. Mirrors
// java/tests/TestInteropServerOracle.java. The Java client is
// graded on its "Test completed." marker; the Go client never
// prints failures except through its FATAL line, so absence of
// FATAL is success there.

final class TestInteropServerOracle
{
    private const CASES = [
        "empty_unary",
        "large_unary",
        "client_streaming",
        "server_streaming",
        "ping_pong",
        "empty_stream",
        "custom_metadata",
        "status_code_and_message",
        "special_status_message",
        "unimplemented_method",
        "unimplemented_service",
        "cancel_after_begin",
        "cancel_after_first_response",
        "timeout_on_sleeping_server",
    ];

    private const JAVA_ONLY = [
        "cacheable_unary",
        "client_compressed_unary",
        "client_compressed_streaming",
        "server_compressed_unary",
        "server_compressed_streaming",
    ];

    private const GO_ONLY = ["orca_per_rpc", "orca_oob"];

    private static function freePort(): int
    {
        $sock = stream_socket_server("tcp://127.0.0.1:0", $errno, $errstr);
        if ($sock === false) {
            throw new \Exception("no free port: $errstr");
        }
        $name = stream_socket_get_name($sock, false);
        fclose($sock);
        return (int)substr($name, strrpos($name, ":") + 1);
    }

    private static function waitReady(string $path, string $needle, int $timeoutSec): bool
    {
        $deadline = microtime(true) + $timeoutSec;
        while (microtime(true) < $deadline) {
            if (file_exists($path) && str_contains(file_get_contents($path), $needle)) {
                return true;
            }
            usleep(50000);
        }
        return false;
    }

    /** Spawn a shell command with output to files; returns exit
     *  status array via proc_get_status polling. */
    private static function spawnToFiles(string $cmd, string $outPath, string $errPath)
    {
        $out = fopen($outPath, "wb");
        $err = fopen($errPath, "wb");
        $proc = proc_open(
            $cmd,
            [0 => ["pipe", "r"], 1 => $out, 2 => $err],
            $pipes
        );
        fclose($pipes[0]);
        fclose($out);
        fclose($err);
        return $proc;
    }

    private static function waitExit($proc, int $timeoutSec): bool
    {
        $deadline = microtime(true) + $timeoutSec;
        while (microtime(true) < $deadline) {
            $status = proc_get_status($proc);
            if (!$status["running"]) {
                return true;
            }
            usleep(50000);
        }
        return false;
    }

    private static function runClient(string $dir, string $tag, string $cmd, ?string $marker): void
    {
        $proc = self::spawnToFiles($cmd, $dir . "/" . $tag . ".out", $dir . "/" . $tag . ".err");
        T::check(self::waitExit($proc, 120), "client did not exit: " . $tag);
        proc_close($proc);
        $output = file_get_contents($dir . "/" . $tag . ".out")
            . file_get_contents($dir . "/" . $tag . ".err");
        if ($marker !== null) {
            T::check(str_contains($output, $marker), "client output for " . $tag . ":\n" . $output);
        } else {
            T::check(!str_contains($output, "FATAL"), "client output for " . $tag . ":\n" . $output);
        }
    }

    public static function run(): void
    {
        $root = T::root();
        $cp = T::javaClasspath($root);
        $dir = sys_get_temp_dir() . "/grpcdc-php-isrv-" . getmypid();
        mkdir($dir, 0777, true);
        $serverBin = T::phpExe() . " " . $root . "/php/examples/interop_server_stdio.php";
        $port = self::freePort();
        $bridge = self::spawnToFiles(
            "node " . $root . "/oracle/bridge.mjs http2-to-dc --port " . $port
                . " --target-cmd '" . $serverBin . "'",
            $dir . "/bridge.out",
            $dir . "/bridge.err"
        );
        if (!self::waitReady($dir . "/bridge.err", "listening", 60)) {
            proc_terminate($bridge, 9);
            proc_close($bridge);
            T::skip("bridge did not start");
        }
        try {
            foreach (array_merge(self::CASES, self::JAVA_ONLY) as $testCase) {
                self::runClient(
                    $dir,
                    "java_" . $testCase,
                    "java -cp " . $cp . " io.grpc.testing.integration.TestServiceClient"
                        . " --server_host=127.0.0.1 --server_port=" . $port
                        . " --test_case=" . $testCase . " --use_tls=false",
                    "Test completed."
                );
                echo "interop B case ok: " . $testCase . " (java client)\n";
            }
            $goClient = $root . "/oracle/go-interop/interop-client";
            if (file_exists($goClient)) {
                foreach (array_merge(self::CASES, self::GO_ONLY) as $testCase) {
                    $cmd = $goClient . " -server_host 127.0.0.1 -server_port " . $port
                        . " -test_case " . $testCase;
                    if (str_starts_with($testCase, "orca")) {
                        $cmd .= " -service_config_json '{ \"loadBalancingConfig\": [{ \"test_backend_metrics_load_balancer\": {} }]}'";
                    }
                    self::runClient($dir, "go_" . $testCase, $cmd, null);
                    echo "interop B case ok: " . $testCase . " (go client)\n";
                }
            } else {
                echo "TestInteropServerOracle GO SKIP (go client not built)\n";
            }
        } finally {
            proc_terminate($bridge, 9);
            proc_close($bridge);
        }
        echo "TestInteropServerOracle OK\n";
    }
}
