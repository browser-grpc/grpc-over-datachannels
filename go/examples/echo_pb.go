// Hand-written protobuf messages for proto/echo.proto (package echo).
//
// Deliberately minimal (two messages) so the example needs no protobuf
// codegen dependency — the wire bytes are genuine protobuf:
// EchoRequest{message:"hi", count:2} encodes to 0a0268691002.

package echo

import (
	"errors"
	"math"
	"unicode/utf8"
)

func appendVarint(out []byte, v uint64) []byte {
	for v > 0x7f {
		out = append(out, byte(v&0x7f)|0x80)
		v >>= 7
	}
	return append(out, byte(v))
}

func appendStringField(out []byte, field int, value string) []byte {
	if value == "" {
		return out
	}
	out = appendVarint(out, uint64(field<<3|2))
	out = appendVarint(out, uint64(len(value)))
	return append(out, value...)
}

func appendInt32Field(out []byte, field int, value int32) []byte {
	if value == 0 {
		return out
	}
	out = appendVarint(out, uint64(field<<3|0))
	return appendVarint(out, uint64(int64(value)))
}

type reader struct {
	buf []byte
	pos int
}

func (r *reader) varint() (uint64, error) {
	var result uint64
	var shift uint
	for {
		if r.pos >= len(r.buf) {
			return 0, errors.New("truncated varint")
		}
		b := r.buf[r.pos]
		r.pos++
		result |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return result, nil
		}
		shift += 7
		if shift >= 64 {
			return 0, errors.New("varint too long")
		}
	}
}

// field returns (fieldNumber, value, done, error); value is uint64 for
// varints and []byte for length-delimited/fixed fields.
func (r *reader) field() (int, any, bool, error) {
	if r.pos >= len(r.buf) {
		return 0, nil, true, nil
	}
	tag, err := r.varint()
	if err != nil {
		return 0, nil, false, err
	}
	num := int(tag >> 3)
	switch tag & 7 {
	case 0:
		v, err := r.varint()
		return num, v, false, err
	case 2:
		n, err := r.varint()
		if err != nil {
			return 0, nil, false, err
		}
		if r.pos+int(n) > len(r.buf) {
			return 0, nil, false, errors.New("truncated bytes field")
		}
		v := r.buf[r.pos : r.pos+int(n)]
		r.pos += int(n)
		return num, v, false, nil
	case 1:
		if r.pos+8 > len(r.buf) {
			return 0, nil, false, errors.New("truncated fixed64")
		}
		v := r.buf[r.pos : r.pos+8]
		r.pos += 8
		return num, v, false, nil
	case 5:
		if r.pos+4 > len(r.buf) {
			return 0, nil, false, errors.New("truncated fixed32")
		}
		v := r.buf[r.pos : r.pos+4]
		r.pos += 4
		return num, v, false, nil
	default:
		return 0, nil, false, errors.New("bad wire type")
	}
}

func asInt32(v any) int32 {
	if n, ok := v.(uint64); ok {
		return int32(n)
	}
	return 0
}

func asString(v any) string {
	if b, ok := v.([]byte); ok && utf8.Valid(b) {
		return string(b)
	}
	return ""
}

var _ = math.MaxInt32

// EchoRequest mirrors proto/echo.proto.
type EchoRequest struct {
	Message string
	Count   int32
	DelayMs int32
}

// MarshalDC encodes the message (grpcdc.Marshaler).
func (m *EchoRequest) MarshalDC() []byte {
	var out []byte
	out = appendStringField(out, 1, m.Message)
	out = appendInt32Field(out, 2, m.Count)
	out = appendInt32Field(out, 3, m.DelayMs)
	return out
}

// UnmarshalDC decodes the message (grpcdc.Unmarshaler).
func (m *EchoRequest) UnmarshalDC(data []byte) error {
	r := &reader{buf: data}
	for {
		field, value, done, err := r.field()
		if err != nil {
			return err
		}
		if done {
			return nil
		}
		switch field {
		case 1:
			m.Message = asString(value)
		case 2:
			m.Count = asInt32(value)
		case 3:
			m.DelayMs = asInt32(value)
		}
	}
}

// EchoResponse mirrors proto/echo.proto.
type EchoResponse struct {
	Message string
	Index   int32
}

// MarshalDC encodes the message (grpcdc.Marshaler).
func (m *EchoResponse) MarshalDC() []byte {
	var out []byte
	out = appendStringField(out, 1, m.Message)
	out = appendInt32Field(out, 2, m.Index)
	return out
}

// UnmarshalDC decodes the message (grpcdc.Unmarshaler).
func (m *EchoResponse) UnmarshalDC(data []byte) error {
	r := &reader{buf: data}
	for {
		field, value, done, err := r.field()
		if err != nil {
			return err
		}
		if done {
			return nil
		}
		switch field {
		case 1:
			m.Message = asString(value)
		case 2:
			m.Index = asInt32(value)
		}
	}
}
