"""Struct corpus driver (python): generated struct codec vs Go golden."""
import sys

from msgs_pb import Hue, Inner, Outer
from msgs2_pb import P2

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

# Proto2 shape (msgs2.proto): explicit defaults, unpacked
# repeated, extension field merged as ext_note. Decode into a
# zero-value message: applying proto2 defaults at decode would
# manufacture presence (enabled=True) the struct bytes do not
# carry.
GOLDEN2_HEX = sys.argv[2]
golden2 = bytes.fromhex(GOLDEN2_HEX)
p2 = P2(
    name="req",
    count=42,
    greeting="hi",
    enabled=False,
    ratio=2.5,
    nums=[5, -6],
    ext_note="note!",
)
got2 = p2.marshal_struct()
if got2.hex() != GOLDEN2_HEX:
    print(f"P2_MARSHAL_MISMATCH\n got {got2.hex()}\nwant {GOLDEN2_HEX}")
    sys.exit(1)
back2 = P2(name="", count=0, greeting="", enabled=False, ratio=0.0, nums=[], ext_note="")
back2.unmarshal_struct(golden2)
if back2.marshal_struct().hex() != GOLDEN2_HEX:
    print("P2_ROUNDTRIP_MISMATCH")
    sys.exit(1)
print("DECODE_OK")
