"""Struct corpus driver (python): generated struct codec vs Go golden."""
import sys

from msgs_pb import Hue, Inner, Outer

GOLDEN_HEX = sys.argv[1]
golden = bytes.fromhex(GOLDEN_HEX)


def inner(v, n=0):
    return Inner(v=v, n=n)


m = Outer(
    inner=inner("x", -3),
    hue=Hue.RED,
    nums=[1, -2, 300],
    by_name={"b": inner("second"), "a": inner("first", 9)},
    s="picked",
    blob=bytes([1, 2, 3]),
    names=["n1", "n2"],
    inners=[inner("i1"), inner("i2"), inner("i3")],
    by_id={7: "seven", 2: "two"},
    score=3.5,
    ratio=0.25,
    flag=True,
    stamp=123456789,
    delta=-77,
)

got = m.marshal_struct()
if got.hex() != GOLDEN_HEX:
    print(f"MARSHAL_MISMATCH\n got {got.hex()}\nwant {GOLDEN_HEX}")
    sys.exit(1)
back = Outer()
back.unmarshal_struct(golden)
if back.marshal_struct().hex() != GOLDEN_HEX:
    print("ROUNDTRIP_MISMATCH")
    sys.exit(1)
print("DECODE_OK")
