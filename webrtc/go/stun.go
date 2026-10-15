// STUN (RFC 8489) Binding messages with short-term credentials:
// MESSAGE-INTEGRITY (HMAC-SHA1) and FINGERPRINT (CRC-32), plus
// XOR-MAPPED-ADDRESS — mirroring webrtc/js/stun.js. Stdlib only.
package dcwebrtc

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"net"
)

// StunMagic is the RFC 8489 magic cookie.
const StunMagic = 0x2112a442

func crc32Stun(buf []byte) uint32 {
	crc := uint32(0xffffffff)
	for _, b := range buf {
		crc = Crc32Table[(crc^uint32(b))&0xff] ^ (crc >> 8)
	}
	return crc ^ 0xffffffff
}

type stunAttr struct {
	typ   uint16
	value []byte
}

// StunMessage is a STUN message with attributes in wire order.
type StunMessage struct {
	Type          uint16
	TransactionID [12]byte
	attrs         []stunAttr
}

func newStunMessage(typ uint16) *StunMessage {
	msg := &StunMessage{Type: typ}
	_, _ = rand.Read(msg.TransactionID[:])
	return msg
}

func (m *StunMessage) addAttr(typ uint16, value []byte) {
	m.attrs = append(m.attrs, stunAttr{typ, value})
}

func (m *StunMessage) attr(typ uint16) []byte {
	for _, a := range m.attrs {
		if a.typ == typ {
			return a.value
		}
	}
	return nil
}

// Encode serializes, optionally appending MESSAGE-INTEGRITY (keyed)
// and FINGERPRINT.
func (m *StunMessage) Encode(integrityKey []byte) []byte {
	var body []byte
	for _, a := range m.attrs {
		if a.typ == StunAttrMessageIntegrity || a.typ == StunAttrFingerprint {
			continue
		}
		body = appendAttr(body, a.typ, a.value)
	}
	header := make([]byte, 20)
	binary.BigEndian.PutUint16(header[0:2], m.Type)
	binary.BigEndian.PutUint32(header[4:8], StunMagic)
	copy(header[8:20], m.TransactionID[:])
	if integrityKey == nil {
		binary.BigEndian.PutUint16(header[2:4], uint16(len(body)))
		return append(header, body...)
	}
	// Stage the length: through MI first (RFC 8489 §14.5); the FP CRC
	// covers the header with the FINAL length (§14.7) already written.
	binary.BigEndian.PutUint16(header[2:4], uint16(len(body)+24))
	mac := hmac.New(sha1.New, integrityKey)
	mac.Write(header)
	mac.Write(body)
	mi := appendAttr(nil, StunAttrMessageIntegrity, mac.Sum(nil))
	binary.BigEndian.PutUint16(header[2:4], uint16(len(body)+24+8))
	beforeFp := append(append(header, body...), mi...)
	fpValue := crc32Stun(beforeFp) ^ 0x5354554e
	fp := make([]byte, 4)
	binary.BigEndian.PutUint32(fp, fpValue)
	return append(beforeFp, appendAttr(nil, StunAttrFingerprint, fp)...)
}

func appendAttr(out []byte, typ uint16, value []byte) []byte {
	var head [4]byte
	binary.BigEndian.PutUint16(head[0:2], typ)
	binary.BigEndian.PutUint16(head[2:4], uint16(len(value)))
	out = append(out, head[:]...)
	out = append(out, value...)
	for pad := (4 - len(value)%4) % 4; pad > 0; pad-- {
		out = append(out, 0)
	}
	return out
}

// DecodeStun parses a STUN message, nil when malformed.
func DecodeStun(data []byte) *StunMessage {
	if len(data) < 20 || binary.BigEndian.Uint32(data[4:8]) != StunMagic {
		return nil
	}
	length := int(binary.BigEndian.Uint16(data[2:4]))
	if 20+length > len(data) {
		return nil
	}
	msg := &StunMessage{Type: binary.BigEndian.Uint16(data[0:2])}
	copy(msg.TransactionID[:], data[8:20])
	pos, end := 20, 20+length
	for pos+4 <= end {
		typ := binary.BigEndian.Uint16(data[pos : pos+2])
		alen := int(binary.BigEndian.Uint16(data[pos+2 : pos+4]))
		if pos+4+alen > end {
			break
		}
		value := make([]byte, alen)
		copy(value, data[pos+4:pos+4+alen])
		msg.attrs = append(msg.attrs, stunAttr{typ, value})
		pos += 4 + (alen+3)/4*4
	}
	return msg
}

// CheckIntegrity verifies MESSAGE-INTEGRITY against key.
func (m *StunMessage) CheckIntegrity(raw, key []byte) bool {
	pos := 20
	for pos+4 <= len(raw) {
		typ := binary.BigEndian.Uint16(raw[pos : pos+2])
		alen := int(binary.BigEndian.Uint16(raw[pos+2 : pos+4]))
		if typ == StunAttrMessageIntegrity {
			prefix := make([]byte, pos)
			copy(prefix, raw[:pos])
			binary.BigEndian.PutUint16(prefix[2:4], uint16(pos-20+24))
			mac := hmac.New(sha1.New, key)
			mac.Write(prefix)
			return hmac.Equal(mac.Sum(nil), raw[pos+4:pos+4+alen])
		}
		pos += 4 + (alen+3)/4*4
	}
	return false
}

// xorAddress encodes an XOR-*ADDRESS value (RFC 5389 §15.2):
// family 1 (IPv4, mask = magic cookie) or family 2 (IPv6, mask
// = magic cookie concatenated with the transaction ID).
// IPv4-mapped IPv6 addresses are encoded as IPv4.
func xorAddress(addr *net.UDPAddr, tid [12]byte) []byte {
	family := byte(1)
	mask := make([]byte, 4)
	binary.BigEndian.PutUint32(mask, StunMagic)
	ip := addr.IP.To4()
	if ip == nil {
		family = 2
		ip = addr.IP.To16()
		mask = append(mask, tid[:]...)
	}
	out := make([]byte, 4+len(ip))
	out[1] = family
	binary.BigEndian.PutUint16(out[2:4], uint16(addr.Port)^(StunMagic>>16))
	for i, b := range ip {
		out[4+i] = b ^ mask[i]
	}
	return out
}

// decodeXorAddress decodes an address attribute value; with xor
// false it decodes the plain (MAPPED-ADDRESS) form.
func decodeXorAddress(value []byte, tid [12]byte, xor bool) *net.UDPAddr {
	if len(value) < 4 {
		return nil
	}
	ipLen := 0
	switch value[1] {
	case 1:
		ipLen = 4
	case 2:
		ipLen = 16
	default:
		return nil
	}
	if len(value) < 4+ipLen {
		return nil
	}
	port := int(binary.BigEndian.Uint16(value[2:4]))
	ip := make(net.IP, ipLen)
	copy(ip, value[4:4+ipLen])
	if xor {
		port ^= StunMagic >> 16
		mask := make([]byte, 4)
		binary.BigEndian.PutUint32(mask, StunMagic)
		if ipLen == 16 {
			mask = append(mask, tid[:]...)
		}
		for i := range ip {
			ip[i] ^= mask[i]
		}
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	return &net.UDPAddr{IP: ip, Port: port}
}

func xorMappedAddress(addr *net.UDPAddr, tid [12]byte) []byte {
	return xorAddress(addr, tid)
}

func bindingSuccess(request *StunMessage, peerAddr *net.UDPAddr, key []byte) []byte {
	resp := &StunMessage{Type: StunTypeBindingSuccess, TransactionID: request.TransactionID}
	resp.addAttr(StunAttrXorMappedAddress, xorMappedAddress(peerAddr, request.TransactionID))
	resp.addAttr(StunAttrSoftware, []byte("dc-webrtc"))
	return resp.Encode(key)
}

func bindingError(request *StunMessage, code int, reason string) []byte {
	resp := &StunMessage{Type: StunTypeBindingError, TransactionID: request.TransactionID}
	value := append([]byte{0, 0, byte(code / 100), byte(code % 100)}, reason...)
	resp.addAttr(StunAttrErrorCode, value)
	return resp.Encode(nil)
}

func hostPriority(component uint32) uint32 {
	return (126 << 24) + (65535 << 8) + (256 - component)
}

func pairPriority(localPrio, remotePrio uint32, weControl bool) uint64 {
	g, d := localPrio, remotePrio
	if !weControl {
		g, d = remotePrio, localPrio
	}
	min, max := g, d
	if min > max {
		min, max = max, min
	}
	result := uint64(min)*4294967296 + uint64(max)*2
	if g > d {
		result++
	}
	return result
}

const iceAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/"

func randomIceString(n int) string {
	raw := make([]byte, n)
	_, _ = rand.Read(raw)
	out := make([]byte, n)
	for i, b := range raw {
		out[i] = iceAlphabet[b%64]
	}
	return string(out)
}

func randomUfrag() string { return randomIceString(6) }

// RFC 8445: ice-pwd must be 22..=256 characters (browsers enforce).
func randomPassword() string { return randomIceString(24) }

var _ = bytes.MinRead
