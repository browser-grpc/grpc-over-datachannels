<?php
// Micro test harness (no dependencies): assertions throw,
// SkipTest skips the current suite with exit 0. Mirrors
// ruby/tests/test_util.rb.

class SkipTest extends \Exception
{
}

final class T
{
    public static function check(bool $cond, string $what): void
    {
        if (!$cond) {
            throw new \Exception("check failed: " . $what);
        }
    }

    public static function assertEq($got, $want, ?string $what = null): void
    {
        if ($got !== $want) {
            throw new \Exception(
                "assertEq failed" . ($what !== null ? " ($what)" : "")
                . ": got " . var_export($got, true) . ", want " . var_export($want, true)
            );
        }
    }

    public static function assertIncludes(string $haystack, string $needle, ?string $what = null): void
    {
        if (!str_contains($haystack, $needle)) {
            throw new \Exception(
                "assertIncludes failed" . ($what !== null ? " ($what)" : "")
                . ": " . var_export($needle, true) . " not in " . var_export($haystack, true)
            );
        }
    }

    public static function skip(string $reason): void
    {
        throw new SkipTest($reason);
    }

    /** Repository root (two levels above php/tests). */
    public static function root(): string
    {
        $env = getenv("GRPC_DC_ROOT");
        if ($env !== false && $env !== "") {
            return $env;
        }
        return dirname(__DIR__, 2);
    }

    public static function phpExe(): string
    {
        // The interpreter running these tests is always right,
        // even when `php` is not on PATH (host installs live
        // outside PATH; Dockerfile.ci puts php-cli on PATH).
        if (PHP_BINARY !== "") {
            return PHP_BINARY;
        }
        $env = getenv("PHP");
        return ($env !== false && $env !== "") ? $env : "php";
    }

    /** Wire loopback peer pumps so either endpoint can drive the other. */
    public static function wirePeerPumps(\Grpcdc\Endpoint $clientEp, \Grpcdc\Endpoint $serverEp): void
    {
        $clientEp->transport->peerPump = function () use ($serverEp) {
            return $serverEp->pump();
        };
        $serverEp->transport->peerPump = function () use ($clientEp) {
            return $clientEp->pump();
        };
    }

    /** Classpath for the Java oracle, or SkipTest when not built. */
    public static function javaClasspath(string $rootPath): string
    {
        $target = $rootPath . "/oracle/java/target";
        $cpFile = $target . "/cp.txt";
        if (!file_exists($cpFile) || !is_dir($target . "/classes")) {
            self::skip("java oracle not built (cd oracle/java && mvn package)");
        }
        return $target . "/classes:" . trim(file_get_contents($cpFile));
    }

    public static function which(string $cmd): bool
    {
        $path = getenv("PATH");
        if ($path === false) {
            return false;
        }
        foreach (explode(PATH_SEPARATOR, $path) as $dir) {
            if ($dir !== "" && is_executable($dir . "/" . $cmd)) {
                return true;
            }
        }
        return false;
    }
}
