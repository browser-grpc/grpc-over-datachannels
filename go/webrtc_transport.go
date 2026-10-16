package grpcdc

// WebRTC transport: adapts a dcwebrtc DataChannel to the grpcdc
// Transport contract (one Send/Recv is one DataChannel message).
// Hand-written adapter; the runtime itself stays transport-agnostic.

import (
	"errors"
	"io"

	dcwebrtc "dcwebrtc"
)

// DcTransport carries grpcdc frames over one WebRTC DataChannel.
type DcTransport struct {
	channel *dcwebrtc.DataChannel
	inbox   chan []byte
}

// NewDcTransport wraps a datachannel. Inbound messages are queued
// from construction, so register it before traffic starts.
func NewDcTransport(channel *dcwebrtc.DataChannel) *DcTransport {
	transport := &DcTransport{channel: channel, inbox: make(chan []byte, 256)}
	channel.OnMessage(func(data []byte, isText bool) {
		cp := make([]byte, len(data))
		copy(cp, data)
		transport.inbox <- cp
	})
	return transport
}

// Send sends one frame as one DataChannel message.
func (t *DcTransport) Send(payload []byte) error {
	if t.channel.ReadyState() != "open" {
		return errors.New("datachannel not open")
	}
	t.channel.Send(payload)
	return nil
}

// Recv returns the next inbound message.
func (t *DcTransport) Recv() ([]byte, error) {
	msg, ok := <-t.inbox
	if !ok {
		return nil, io.EOF
	}
	return msg, nil
}
