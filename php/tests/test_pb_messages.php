<?php
// Generated PHP message types (<base>_pb.php) from the native
// protoc-gen-grpc-dc-php plugin: kitchen-sink round-trip plus a
// protoc oracle — protoc's own --encode bytes must decode to the
// same message and re-encode semantically identically.

final class TestPbMessages
{
    public static function run(): void
    {
        $root = T::root();
        $tmp = "/tmp/grpcdc-php-pb";
        $gen = $tmp . "/gen";
        self::runCmd("rm -rf " . escapeshellarg($tmp));
        self::runCmd("mkdir -p " . escapeshellarg($gen));
        self::runCmd(
            "protoc --plugin=protoc-gen-grpc-dc-php=" . $root . "/bin/protoc-gen-grpc-dc-php"
            . " --grpc-dc-php_out=" . $gen . " -I " . $root . "/webapp/testdata common.proto kitchen.proto"
        );
        @unlink($gen . "/common_grpc_dc.php");
        @unlink($gen . "/kitchen_grpc_dc.php");
        file_put_contents($gen . "/harness.php", self::HARNESS);

        $php = getenv("PHP") ?: "php";
        $out1 = self::capture($php . " " . $gen . "/harness.php roundtrip");
        T::assertIncludes($out1, "roundtrip OK");

        file_put_contents($tmp . "/kitchen.txt", self::KITCHEN_TEXT);
        self::runCmd(
            "protoc --encode=kitchen.v1.Kitchen -I " . $root . "/webapp/testdata kitchen.proto"
            . " < " . $tmp . "/kitchen.txt > " . $tmp . "/protoc.bin"
        );
        $out2 = self::capture($php . " " . $gen . "/harness.php oracle " . $tmp . "/protoc.bin");
        T::assertIncludes($out2, "oracle OK");
        echo "TestPbMessages OK\n";
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

    private const KITCHEN_TEXT = <<<'TEXT'
        d: 1.5 f: 2.5 i32: -3 i64: -4 u32: 5 u64: 6 s32: -7 s64: -8
        f32: 9 f64: 10 sf32: -11 sf64: -12 flag: true name: "sink"
        blob: "\x01\x02\x03" color: GREEN
        nested { note: "n" level: 3 }
        item { sku: "abc" quantity: 2 }
        nums: [1, -2, 300] words: ["a", "", "bc"]
        manys { note: "m" level: 1 }
        vals: [0.5, -1.25]
        counts { key: "x" value: 1 } counts { key: "y" value: -2 }
        by_id { key: 7 value { note: "z" level: 9 } }
        text: "chosen" big_negative: -9007199254740993 neg32: -123456
        TEXT;

    private const HARNESS = <<<'PHP'
        <?php
        require_once __DIR__ . "/kitchen_pb.php";
        require_once __DIR__ . "/common_pb.php";

        use KitchenPb\Kitchen;
        use KitchenPb\Nested;
        use KitchenPb\Color;
        use CommonPb\Item;

        function fail(string $msg): void
        {
            fwrite(STDERR, "FAIL: $msg\n");
            exit(1);
        }

        function make(): Kitchen
        {
            return new Kitchen(
                1.5, 2.5, -3, -4, 5, 6, -7, -8, 9, 10, -11, -12,
                true, "sink", "\x01\x02\x03", Color::GREEN,
                new Nested("n", 3), new Item("abc", 2),
                [1, -2, 300], ["a", "", "bc"], [new Nested("m", 1)],
                [0.5, -1.25], ["x" => 1, "y" => -2],
                [7 => new Nested("z", 9)],
                "chosen", 0, -9007199254740993, -123456);
        }

        function checkSame(Kitchen $a, Kitchen $b): void
        {
            $ok = $a->d === $b->d && $a->f === $b->f && $a->i32 === $b->i32
                && $a->i64 === $b->i64 && $a->u32 === $b->u32 && $a->u64 === $b->u64
                && $a->s32 === $b->s32 && $a->s64 === $b->s64
                && $a->f32 === $b->f32 && $a->f64 === $b->f64
                && $a->sf32 === $b->sf32 && $a->sf64 === $b->sf64
                && $a->flag === $b->flag && $a->name === $b->name && $a->blob === $b->blob
                && $a->color === $b->color
                && $a->nested->note === $b->nested->note && $a->nested->level === $b->nested->level
                && $a->item->sku === $b->item->sku && $a->item->quantity === $b->item->quantity
                && $a->nums === $b->nums && $a->words === $b->words
                && count($a->manys) === 1 && $a->manys[0]->note === $b->manys[0]->note
                && $a->vals === $b->vals && $a->counts === $b->counts
                && $a->byId[7]->note === $b->byId[7]->note && $a->byId[7]->level === $b->byId[7]->level
                && $a->text === $b->text && $a->bigNegative === $b->bigNegative
                && $a->neg32 === $b->neg32;
            if (!$ok) {
                fail("mismatch");
            }
        }

        $k = make();
        if ($argv[1] === "roundtrip") {
            $back = new Kitchen();
            $back->unmarshalDc($k->marshalDc());
            checkSame($back, $k);
            if ((new Kitchen())->marshalDc() !== "") {
                fail("empty");
            }
            $both = new Kitchen();
            $both->text = "a";
            $both->code = 7;
            $bothBack = new Kitchen();
            $bothBack->unmarshalDc($both->marshalDc());
            if ($bothBack->text !== "" || $bothBack->code !== 7) {
                fail("oneof encode clearing");
            }
            echo "roundtrip OK\n";
        } else {
            $from = new Kitchen();
            $from->unmarshalDc(file_get_contents($argv[2]));
            checkSame($from, $k);
            $again = new Kitchen();
            $again->unmarshalDc($from->marshalDc());
            checkSame($again, $from);
            echo "oracle OK\n";
        }
        PHP;
}
