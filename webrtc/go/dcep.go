// DCEP (RFC 8832): DATA_CHANNEL_OPEN/ACK over SCTP PPID 50, and the
// channel-type/reliability mapping — mirroring webrtc/js/dcep.js.
package dcwebrtc

import "encoding/binary"

// SCTP payload protocol identifiers for WebRTC datachannels.
const (
	PpidDcep        = 50
	PpidString      = 51
	PpidBinary      = 53
	PpidStringEmpty = 56
	PpidBinaryEmpty = 57
)

const (
	dcepMsgOpen = 0x03
	dcepMsgAck  = 0x02
)

// Channel types (RFC 8832 §5.1).
const (
	ChannelReliable             = 0x00
	ChannelReliableUnordered    = 0x80
	ChannelPartialRexmit        = 0x01
	ChannelPartialRexmitUnord   = 0x81
	ChannelPartialLifetime      = 0x02
	ChannelPartialLifetimeUnord = 0x82
)

// ChannelParams describes a datachannel to open.
type ChannelParams struct {
	Label          string
	Ordered        bool
	MaxRetransmits *uint32
	MaxLifetimeMs  *int64
}

// DefaultChannelParams returns reliable ordered defaults.
func DefaultChannelParams(label string) ChannelParams {
	return ChannelParams{Label: label, Ordered: true}
}

func (p ChannelParams) channelType() byte {
	var t byte
	switch {
	case p.MaxRetransmits != nil:
		t = ChannelPartialRexmit
	case p.MaxLifetimeMs != nil:
		t = ChannelPartialLifetime
	default:
		t = ChannelReliable
	}
	if !p.Ordered {
		t |= 0x80
	}
	return t
}

func (p ChannelParams) reliabilityParam() uint32 {
	switch {
	case p.MaxRetransmits != nil:
		return uint32(*p.MaxRetransmits)
	case p.MaxLifetimeMs != nil:
		return uint32(*p.MaxLifetimeMs)
	default:
		return 0
	}
}

// SendOptions maps the params onto SCTP send options.
func (p ChannelParams) SendOptions() SendOptions {
	return SendOptions{
		Unordered:      !p.Ordered,
		MaxRetransmits: p.MaxRetransmits,
		MaxLifetimeMs:  p.MaxLifetimeMs,
	}
}

// ChannelParamsFromType reverses a channel-type byte + reliability.
func ChannelParamsFromType(channelType byte, reliability uint32, label string) ChannelParams {
	params := DefaultChannelParams(label)
	params.Ordered = channelType&0x80 == 0
	switch channelType & 0x7f {
	case ChannelPartialRexmit:
		v := reliability
		params.MaxRetransmits = &v
	case ChannelPartialLifetime:
		v := int64(reliability)
		params.MaxLifetimeMs = &v
	}
	return params
}

// EncodeOpen builds a DATA_CHANNEL_OPEN payload.
func EncodeOpen(params ChannelParams) []byte {
	label := []byte(params.Label)
	out := make([]byte, 12+len(label))
	out[0] = dcepMsgOpen
	out[1] = params.channelType()
	binary.BigEndian.PutUint16(out[2:4], 0) // priority
	binary.BigEndian.PutUint32(out[4:8], params.reliabilityParam())
	binary.BigEndian.PutUint16(out[8:10], uint16(len(label)))
	binary.BigEndian.PutUint16(out[10:12], 0) // protocol length
	copy(out[12:], label)
	return out
}

// DcepMessage is a decoded OPEN (Params set) or ACK.
type DcepMessage struct {
	IsAck  bool
	Params ChannelParams
}

// DecodeDcep parses an OPEN or ACK payload, nil when malformed.
func DecodeDcep(data []byte) *DcepMessage {
	if len(data) < 1 {
		return nil
	}
	if data[0] == dcepMsgAck {
		return &DcepMessage{IsAck: true}
	}
	if data[0] != dcepMsgOpen || len(data) < 12 {
		return nil
	}
	channelType := data[1]
	reliability := binary.BigEndian.Uint32(data[4:8])
	labelLen := int(binary.BigEndian.Uint16(data[8:10]))
	protocolLen := int(binary.BigEndian.Uint16(data[10:12]))
	if 12+labelLen+protocolLen > len(data) {
		return nil
	}
	label := string(data[12 : 12+labelLen])
	return &DcepMessage{Params: ChannelParamsFromType(channelType, reliability, label)}
}

// EncodeAck builds a DATA_CHANNEL_ACK payload.
func EncodeAck() []byte { return []byte{dcepMsgAck} }
