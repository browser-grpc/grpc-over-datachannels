<?php
// Struct corpus driver (php): generated struct codec vs Go golden.
require_once __DIR__ . "/msgs_pb.php";
require_once __DIR__ . "/msgs2_pb.php";

use MsgsPb\Outer;
use MsgsPb\Inner;
use MsgsPb\Hue;
use Msgs2Pb\P2;

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

// Proto2 shape (msgs2.proto): explicit defaults, unpacked
// repeated, extension field merged as extNote. Decode into a
// zero-value message: applying proto2 defaults at decode would
// manufacture presence (enabled=true) the struct bytes do not
// carry.
$golden2Hex = $argv[2];
$golden2 = hex2bin($golden2Hex);
$p2 = new P2("req", 42, "hi", false, 2.5, [5, -6], "note!");
$got2 = $p2->marshalStruct();
if (bin2hex($got2) !== $golden2Hex) {
    echo "P2_MARSHAL_MISMATCH\n got " . bin2hex($got2) . "\nwant $golden2Hex\n";
    exit(1);
}
$back2 = new P2("", 0, "", false, 0.0, [], "");
$back2->unmarshalStruct($golden2);
if (bin2hex($back2->marshalStruct()) !== $golden2Hex) {
    echo "P2_ROUNDTRIP_MISMATCH\n";
    exit(1);
}
echo "DECODE_OK\n";
