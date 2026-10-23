package grpcdc

// WebRTC-Direct (libp2p-style) client->server helpers: no ICE,
// no SDP exchange. The listener is identified by the certhash in
// its multiaddr; dialers pin the listener certificate to it.
// The TURN variant is the symmetric-NAT path (the whole DTLS
// session rides a TURN allocation). See dcwebrtc direct.go.

import (
	"errors"
	"time"

	dcwebrtc "dcwebrtc"
)

// DirectListener binds a WebRTC-Direct listener. Its Multiaddr
// (address + certhash) is everything a dialer needs.
func DirectListener(addr string) (*dcwebrtc.DirectListener, error) {
	return dcwebrtc.NewDirectListener(addr, nil)
}

// AcceptDirectTransport accepts one direct connection and its
// "grpc" channel; serve it with Server.ServeTransport.
func AcceptDirectTransport(listener *dcwebrtc.DirectListener) (*DcTransport, error) {
	endpoint, err := listener.Accept()
	if err != nil {
		return nil, err
	}
	channelCh := make(chan *dcwebrtc.DataChannel, 1)
	endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
		channelCh <- channel
	})
	select {
	case channel := <-channelCh:
		return NewDcTransport(channel), nil
	case <-time.After(30 * time.Second):
		return nil, errors.New("webrtc-direct: no channel opened")
	}
}

// DirectClientTransport dials a Direct listener by multiaddr
// and opens the "grpc" channel; build a generated client with
// NewChannel(transport).
func DirectClientTransport(multiaddr string) (*DcTransport, error) {
	endpoint, err := dcwebrtc.DirectDialMultiaddr(multiaddr, nil)
	if err != nil {
		return nil, err
	}
	channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("grpc"))
	return NewDcTransport(channel), nil
}

// DirectClientTurnTransport dials a Direct listener by
// multiaddr through a TURN allocation (symmetric-NAT path).
func DirectClientTurnTransport(multiaddr string, turn dcwebrtc.TurnServerConfig) (*DcTransport, error) {
	endpoint, err := dcwebrtc.DirectDialTurnMultiaddr(multiaddr, nil, turn)
	if err != nil {
		return nil, err
	}
	channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("grpc"))
	return NewDcTransport(channel), nil
}

// DirectClientEndpoint dials a Direct listener by multiaddr
// and returns the raw endpoint (no channel opened yet). Use it
// to open extra application channels next to the "grpc" one --
// including lossy or unordered ones, via
// endpoint.OpenChannel(dcwebrtc.ChannelParams{Label: "...",
// Ordered: false, MaxRetransmits: &n}) or MaxLifetimeMs. The
// "grpc" channel itself must stay reliable and ordered:
// grpc-dc framing assumes in-order reliable delivery, so keep
// DirectClientTransport's defaults for gRPC traffic and use
// lossy channels only for application data that tolerates
// drops and reordering.
func DirectClientEndpoint(multiaddr string) (*dcwebrtc.DcEndpoint, error) {
	return dcwebrtc.DirectDialMultiaddr(multiaddr, nil)
}

// DirectClientTurnEndpoint is DirectClientEndpoint through a
// TURN allocation (symmetric-NAT path).
func DirectClientTurnEndpoint(multiaddr string, turn dcwebrtc.TurnServerConfig) (*dcwebrtc.DcEndpoint, error) {
	return dcwebrtc.DirectDialTurnMultiaddr(multiaddr, nil, turn)
}

// AcceptDirectEndpoint accepts one direct connection and
// returns the raw endpoint (its "grpc" channel not yet
// consumed). Incoming application channels -- including
// lossy/unordered ones opened by the dialer -- surface through
// endpoint.SetOnChannel; see DirectClientEndpoint for the
// reliability contract.
func AcceptDirectEndpoint(listener *dcwebrtc.DirectListener) (*dcwebrtc.DcEndpoint, error) {
	return listener.Accept()
}
