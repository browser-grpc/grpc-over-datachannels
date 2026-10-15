"""Hand-written protobuf messages for proto/echo.proto (package echo).

Deliberately minimal (two messages) so the example needs no protobuf
codegen dependency — the wire bytes are genuine protobuf:
EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
Mirrors go/examples/echo_pb.go.
"""


def _append_varint(out, value):
    v = value & 0xFFFFFFFFFFFFFFFF
    while v > 0x7F:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return out


def _append_string_field(out, field, value):
    if value == "":
        return out
    data = value.encode("utf-8")
    out = _append_varint(out, (field << 3) | 2)
    out = _append_varint(out, len(data))
    out.extend(data)
    return out


def _append_int32_field(out, field, value):
    if value == 0:
        return out
    out = _append_varint(out, (field << 3) | 0)
    return _append_varint(out, value & 0xFFFFFFFFFFFFFFFF)


class _Reader:
    def __init__(self, buf):
        self.buf = buf
        self.pos = 0

    def varint(self):
        result = 0
        shift = 0
        while True:
            if self.pos >= len(self.buf):
                raise ValueError("truncated varint")
            b = self.buf[self.pos]
            self.pos += 1
            result |= (b & 0x7F) << shift
            if not (b & 0x80):
                return result
            shift += 7
            if shift >= 64:
                raise ValueError("varint too long")

    def field(self):
        """(field_number, value) or None at end; value is int or bytes."""
        if self.pos >= len(self.buf):
            return None
        tag = self.varint()
        num, wire = tag >> 3, tag & 7
        if wire == 0:
            return num, self.varint()
        if wire == 2:
            n = self.varint()
            if self.pos + n > len(self.buf):
                raise ValueError("truncated bytes field")
            value = self.buf[self.pos : self.pos + n]
            self.pos += n
            return num, value
        if wire == 1:
            if self.pos + 8 > len(self.buf):
                raise ValueError("truncated fixed64")
            value = self.buf[self.pos : self.pos + 8]
            self.pos += 8
            return num, value
        if wire == 5:
            if self.pos + 4 > len(self.buf):
                raise ValueError("truncated fixed32")
            value = self.buf[self.pos : self.pos + 4]
            self.pos += 4
            return num, value
        raise ValueError("bad wire type")


def _as_int32(value):
    if isinstance(value, int):
        return ((value & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
    return 0


def _as_string(value):
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("utf-8")
    return ""


class EchoRequest:
    """Mirrors proto/echo.proto EchoRequest."""

    def __init__(self, message="", count=0, delay_ms=0):
        self.message = message
        self.count = count
        self.delay_ms = delay_ms

    def marshal_dc(self):
        out = bytearray()
        out = _append_string_field(out, 1, self.message)
        out = _append_int32_field(out, 2, self.count)
        out = _append_int32_field(out, 3, self.delay_ms)
        return bytes(out)

    def unmarshal_dc(self, data):
        self.message, self.count, self.delay_ms = "", 0, 0
        reader = _Reader(data)
        while True:
            item = reader.field()
            if item is None:
                return self
            num, value = item
            if num == 1:
                self.message = _as_string(value)
            elif num == 2:
                self.count = _as_int32(value)
            elif num == 3:
                self.delay_ms = _as_int32(value)

    def __eq__(self, other):
        return (
            isinstance(other, EchoRequest)
            and (self.message, self.count, self.delay_ms)
            == (other.message, other.count, other.delay_ms)
        )

    def __repr__(self):
        return (
            f"EchoRequest(message={self.message!r}, count={self.count}, "
            f"delay_ms={self.delay_ms})"
        )


class EchoResponse:
    """Mirrors proto/echo.proto EchoResponse."""

    def __init__(self, message="", index=0):
        self.message = message
        self.index = index

    def marshal_dc(self):
        out = bytearray()
        out = _append_string_field(out, 1, self.message)
        out = _append_int32_field(out, 2, self.index)
        return bytes(out)

    def unmarshal_dc(self, data):
        self.message, self.index = "", 0
        reader = _Reader(data)
        while True:
            item = reader.field()
            if item is None:
                return self
            num, value = item
            if num == 1:
                self.message = _as_string(value)
            elif num == 2:
                self.index = _as_int32(value)

    def __eq__(self, other):
        return (
            isinstance(other, EchoResponse)
            and (self.message, self.index) == (other.message, other.index)
        )

    def __repr__(self):
        return f"EchoResponse(message={self.message!r}, index={self.index})"
