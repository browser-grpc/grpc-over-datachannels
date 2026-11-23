<?php
// Struct corpus driver (php): generated struct codec vs Go golden.
require_once __DIR__ . "/msgs_pb.php";

use MsgsPb\Outer;
use MsgsPb\Inner;
use MsgsPb\Hue;

$goldenHex = $argv[1];
$golden = hex2bin($goldenHex);

function inner(string $v, int $n = 0): Inner
{
    return new Inner($v, $n);
}

$m = new Outer(
    inner("x", -3),
    Hue::RED,
    [1, -2, 300],
    ["b" => inner("second"), "a" => inner("first", 9)],
    "picked",
    0,
    "\x01\x02\x03",
    ["n1", "n2"],
    [inner("i1"), inner("i2"), inner("i3")],
    [7 => "seven", 2 => "two"],
    3.5,
    0.25,
    true,
    123456789,
    -77
);

$got = $m->marshalStruct();
if (bin2hex($got) !== $goldenHex) {
    echo "MARSHAL_MISMATCH\n got " . bin2hex($got) . "\nwant $goldenHex\n";
    exit(1);
}
$back = new Outer();
$back->unmarshalStruct($golden);
if (bin2hex($back->marshalStruct()) !== $goldenHex) {
    echo "ROUNDTRIP_MISMATCH\n";
    exit(1);
}
echo "DECODE_OK\n";
