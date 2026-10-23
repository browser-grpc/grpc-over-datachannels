<?php
// BDD schema scenarios: golden protoc bytes, generated classes.
// The case table (bdd_schemas_generated.php, generated from
// the schema scenarios) carries protoc's own --encode output
// over webapp/testdata/{kitchen,features}.proto. Each case
// decodes with the generated classes and re-encodes
// byte-identically. The generated-classes harness mirrors
// test_pb_messages.php.

final class TestBddSchemas
{
    public static function run(): void
    {
        require_once __DIR__ . "/bdd_schemas_generated.php";

        $root = T::root();
        $tmp = "/tmp/grpcdc-php-schemas";
        $gen = $tmp . "/gen";
        self::runCmd("rm -rf " . escapeshellarg($tmp));
        self::runCmd("mkdir -p " . escapeshellarg($gen));
        self::runCmd(
            "protoc --plugin=protoc-gen-grpc-dc-php=" . $root . "/bin/protoc-gen-grpc-dc-php"
            . " --grpc-dc-php_out=" . $gen . " -I " . $root . "/webapp/testdata common.proto kitchen.proto features.proto"
        );
        @unlink($gen . "/common_grpc_dc.php");
        @unlink($gen . "/kitchen_grpc_dc.php");
        @unlink($gen . "/features_grpc_dc.php");

        $rows = "";
        foreach (BDD_SCHEMAS as $row) {
            $rows .= "    [" . implode(", ", array_map(
                static fn($v) => var_export($v, true),
                $row
            )) . "],\n";
        }
        file_put_contents($gen . "/harness.php", str_replace("CASES", $rows, self::HARNESS));

        $php = getenv("PHP") ?: "php";
        $out = self::capture($php . " " . $gen . "/harness.php");
        T::assertIncludes($out, "schemas OK");
        echo "TestBddSchemas OK\n";
    }

    private static function runCmd(string $cmd): void
    {
        exec($cmd . " 2>&1", $out, $code);
        if ($code !== 0) {
            throw new \Exception("command failed: $cmd -> " . implode("\n", $out));
        }
    }

    private static function capture(string $cmd): string
    {
        exec($cmd . " 2>&1", $out, $code);
        $text = implode("\n", $out);
        if ($code !== 0) {
            throw new \Exception("capture failed: $cmd -> $text");
        }
        return $text;
    }

    private const HARNESS = <<<'PHP'
        <?php
        require_once __DIR__ . "/kitchen_pb.php";
        require_once __DIR__ . "/features_pb.php";

        use KitchenPb\Kitchen;
        use FeaturesPb\Outer;

        function fail(string $msg): void
        {
            fwrite(STDERR, "FAIL: $msg\n");
            exit(1);
        }

        $cases = [
        CASES
        ];

        foreach ($cases as [$name, $message, $input, $expect]) {
            if ($message === "kitchen") {
                $m = new Kitchen();
            } elseif ($message === "outer") {
                $m = new Outer();
            } else {
                fail("unknown message " . $message);
            }
            $m->unmarshalDc(hex2bin($input));
            $got = $m->marshalDc();
            if (bin2hex($got) !== $expect) {
                fail("re-encode mismatch: " . $name);
            }
        }
        echo "schemas OK\n";
        PHP;
}
