package grpcdc_test

// gRPC (generated grpcdc runtime) over WebRTC-Direct: generated
// Echo client dials a generated server by multiaddr only
// (address + certhash), via the grpcdc direct helpers.

import (
	"context"
	"io"
	"testing"
	"time"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"

	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
)

func TestGrpcOverGoWebRtcDirect(t *testing.T) {
	listener, err := grpcdc.DirectListener("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	multiaddr := listener.Multiaddr()

	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	go func() {
		transport, err := grpcdc.AcceptDirectTransport(listener)
		if err != nil {
			t.Errorf("accept direct: %v", err)
			return
		}
		server.ServeTransport(transport)
	}()

	transport, err := grpcdc.DirectClientTransport(multiaddr)
	if err != nil {
		t.Fatalf("direct client: %v", err)
	}
	client := echo.NewEchoClient(grpcdc.NewChannel(transport))
	ctx := context.Background()

	unary, err := client.Unary(ctx, &echo.EchoRequest{Message: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if unary.Message != "echo: hello" {
		t.Fatalf("unary = %q", unary.Message)
	}

	stream, err := client.ServerStream(ctx, &echo.EchoRequest{Message: "tick", Count: 3})
	if err != nil {
		t.Fatal(err)
	}
	var indexes []int32
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		indexes = append(indexes, resp.Index)
	}
	if len(indexes) != 3 || indexes[0] != 0 || indexes[1] != 1 || indexes[2] != 2 {
		t.Fatalf("indexes = %v", indexes)
	}
	_ = time.Second
}

// A lossy, unordered application channel opened next to the
// grpc channel through the adapter's endpoint surface: the
// channel is negotiated maxRetransmits=0 + unordered via
// dcwebrtc.ChannelParams.
func TestLossyUnorderedAppChannelNextToGrpc(t *testing.T) {
	listener, err := grpcdc.DirectListener("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	got := make(chan []byte, 1)
	go func() {
		endpoint, err := grpcdc.AcceptDirectEndpoint(listener)
		if err != nil {
			t.Errorf("accept endpoint: %v", err)
			return
		}
		endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
			channel.OnMessage(func(data []byte, isText bool) {
				got <- append([]byte(nil), data...)
			})
		})
	}()

	endpoint, err := grpcdc.DirectClientEndpoint(listener.Multiaddr())
	if err != nil {
		t.Fatalf("client endpoint: %v", err)
	}
	defer endpoint.Close()
	zero := uint32(0)
	channel := endpoint.OpenChannel(dcwebrtc.ChannelParams{
		Label: "telemetry", Ordered: false, MaxRetransmits: &zero,
	})
	channel.Send([]byte("ping-lossy"))
	select {
	case data := <-got:
		if string(data) != "ping-lossy" {
			t.Fatalf("got %q", data)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("app channel message never arrived")
	}
}
