package grpcdc_test

// Rendezvous (grpcdc.ServeRendezvous): a Go Peer dialer
// synthesizes the listener's descriptor locally, runs ICE as
// controlling agent, and runs generated Echo stubs over the
// resulting "grpc" DataChannel — no signaling exchange.

import (
	"context"
	"net"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
)

func TestRendezvousEcho(t *testing.T) {
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	listener, err := grpcdc.ServeRendezvous(server,
		&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0},
		dcwebrtc.RendezvousOptions{LocalIPs: []string{"127.0.0.1"}})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	desc := listener.Descriptor("127.0.0.1")

	dialer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{
		LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer dialer.Close()
	remote := dcwebrtc.SessionDescription{
		Ufrag:       desc.IceUfrag,
		Pwd:         desc.IcePwd,
		Fingerprint: desc.Fingerprint,
		Setup:       "passive",
		Candidates:  []dcwebrtc.Candidate{dcwebrtc.HostCandidate("127.0.0.1", desc.Port, "1")},
	}
	if err := dialer.HandleAnswer(remote.Generate("answer")); err != nil {
		t.Fatal(err)
	}
	endpoint, err := dialer.ConnectWithOptions(true)
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()
	channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("grpc"))
	client := echo.NewEchoClient(grpcdc.NewChannel(grpcdc.NewDcTransport(channel)))
	unary, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if unary.Message != "echo: hello" {
		t.Fatalf("unary = %q", unary.Message)
	}
}
