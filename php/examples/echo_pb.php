<?php
// Hand-written protobuf messages for proto/echo.proto (package echo).
//
// Deliberately minimal (two messages) so the example needs no protobuf
// codegen dependency — the wire bytes are genuine protobuf:
// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.
// Mirrors ruby/examples/echo_pb.rb.

namespace EchoPb;

function appendVarint(string &$out, int $value): void
{
    $v = $value;
    while (true) {
        $b = $v & 0x7F;
        $v = ($v >> 7) & 0x01FFFFFFFFFFFFFF; // logical shift on the 64-bit pattern
        if ($v === 0) {
            $out .= chr($b);
            return;
        }
        $out .= chr($b | 0x80);
    }
}

function appendStringField(string &$out, int $field, string $value): void
{
    if ($value === "") {
        return;
    }
    appendVarint($out, ($field << 3) | 2);
    appendVarint($out, strlen($value));
    $out .= $value;
}

function appendInt32Field(string &$out, int $field, int $value): void
{
    if ($value === 0) {
        return;
    }
    appendVarint($out, ($field << 3) | 0);
    appendVarint($out, $value);
}

class Reader
{
    private string $buf;
    private int $pos = 0;

    public function __construct(string $buf)
    {
        $this->buf = $buf;
    }

    public function varint(): int
    {
        $result = 0;
        $shift = 0;
        while (true) {
            if ($this->pos >= strlen($this->buf)) {
                throw new \InvalidArgumentException("truncated varint");
            }
            $b = ord($this->buf[$this->pos]);
            $this->pos++;
            if ($shift < 63) {
                $result |= ($b & 0x7F) << $shift;
            } elseif (($b & 1) !== 0) {
                $result |= PHP_INT_MIN;
            }
            if (($b & 0x80) === 0) {
                return $result;
            }
            $shift += 7;
            if ($shift >= 64) {
                throw new \InvalidArgumentException("varint too long");
            }
        }
    }

    /** [field_number, value] or null at end; value is int or string. */
    public function field(): ?array
    {
        if ($this->pos >= strlen($this->buf)) {
            return null;
        }
        $tag = $this->varint();
        $num = $tag >> 3;
        $wire = $tag & 7;
        switch ($wire) {
            case 0:
                return [$num, $this->varint()];
            case 2:
                $n = $this->varint();
                if ($this->pos + $n > strlen($this->buf)) {
                    throw new \InvalidArgumentException("truncated bytes field");
                }
                $value = substr($this->buf, $this->pos, $n);
                $this->pos += $n;
                return [$num, $value];
            case 1:
                if ($this->pos + 8 > strlen($this->buf)) {
                    throw new \InvalidArgumentException("truncated fixed64");
                }
                $value = substr($this->buf, $this->pos, 8);
                $this->pos += 8;
                return [$num, $value];
            case 5:
                if ($this->pos + 4 > strlen($this->buf)) {
                    throw new \InvalidArgumentException("truncated fixed32");
                }
                $value = substr($this->buf, $this->pos, 4);
                $this->pos += 4;
                return [$num, $value];
            default:
                throw new \InvalidArgumentException("bad wire type");
        }
    }
}

function asInt32($value): int
{
    if (!is_int($value)) {
        return 0;
    }
    $v = $value & 0xFFFFFFFF;
    return $v >= 0x80000000 ? $v - 0x100000000 : $v;
}

function asString($value): string
{
    return is_string($value) ? $value : "";
}

// Mirrors proto/echo.proto EchoRequest.
class EchoRequest
{
    public string $message = "";
    public int $count = 0;
    public int $delayMs = 0;

    public function __construct(string $message = "", int $count = 0, int $delayMs = 0)
    {
        $this->message = $message;
        $this->count = $count;
        $this->delayMs = $delayMs;
    }

    public function marshalDc(): string
    {
        $out = "";
        appendStringField($out, 1, $this->message);
        appendInt32Field($out, 2, $this->count);
        appendInt32Field($out, 3, $this->delayMs);
        return $out;
    }

    public function unmarshalDc(string $data): self
    {
        $this->message = "";
        $this->count = 0;
        $this->delayMs = 0;
        $reader = new Reader($data);
        while (($item = $reader->field()) !== null) {
            [$num, $value] = $item;
            switch ($num) {
                case 1:
                    $this->message = asString($value);
                    break;
                case 2:
                    $this->count = asInt32($value);
                    break;
                case 3:
                    $this->delayMs = asInt32($value);
                    break;
            }
        }
        return $this;
    }

    public function equals(?object $other): bool
    {
        return $other instanceof EchoRequest
            && $this->message === $other->message
            && $this->count === $other->count
            && $this->delayMs === $other->delayMs;
    }
}

// Mirrors proto/echo.proto EchoResponse.
class EchoResponse
{
    public string $message = "";
    public int $index = 0;

    public function __construct(string $message = "", int $index = 0)
    {
        $this->message = $message;
        $this->index = $index;
    }

    public function marshalDc(): string
    {
        $out = "";
        appendStringField($out, 1, $this->message);
        appendInt32Field($out, 2, $this->index);
        return $out;
    }

    public function unmarshalDc(string $data): self
    {
        $this->message = "";
        $this->index = 0;
        $reader = new Reader($data);
        while (($item = $reader->field()) !== null) {
            [$num, $value] = $item;
            switch ($num) {
                case 1:
                    $this->message = asString($value);
                    break;
                case 2:
                    $this->index = asInt32($value);
                    break;
            }
        }
        return $this;
    }

    public function equals(?object $other): bool
    {
        return $other instanceof EchoResponse
            && $this->message === $other->message
            && $this->index === $other->index;
    }
}
