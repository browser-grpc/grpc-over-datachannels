package grpcdc_test

// gRPC (generated grpcdc runtime) over the native Go WebRTC stack:
// two dcwebrtc Peers, an Echo server on the answerer, and unary +
// streaming calls from the offerer — the Go equivalent of
// rust/tests/webrtc_grpc.rs.

import (
	"context"
	"io"
	"testing"
	"time"

	dcwebrtc "dcwebrtc"
	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func TestGrpcOverGoWebRtc(t *testing.T) {
	offererPeer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{
		LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer offererPeer.Close()
	answererPeer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{
		LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer answererPeer.Close()

	offer := offererPeer.CreateOffer()
	answer, err := answererPeer.HandleOffer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err := offererPeer.HandleAnswer(answer); err != nil {
		t.Fatal(err)
	}

	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	type connectResult struct {
		endpoint *dcwebrtc.DcEndpoint
		err      error
	}
	answererCh := make(chan connectResult, 1)
	go func() {
		endpoint, err := answererPeer.ConnectWithOptions(true)
		if endpoint != nil {
			endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
				server.ServeTransport(grpcdc.NewDcTransport(channel))
			})
		}
		answererCh <- connectResult{endpoint, err}
	}()
	offererEndpoint, err := offererPeer.ConnectWithOptions(true)
	if err != nil {
		t.Fatalf("offerer connect: %v", err)
	}
	select {
	case result := <-answererCh:
		if result.err != nil {
			t.Fatalf("answerer connect: %v", result.err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("answerer connect timed out")
	}

	channel := offererEndpoint.OpenChannel(dcwebrtc.DefaultChannelParams("grpc"))
	client := echo.NewEchoClient(grpcdc.NewChannel(grpcdc.NewDcTransport(channel)))
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
		if resp.Message != "tick" {
			t.Fatalf("stream message = %q", resp.Message)
		}
		indexes = append(indexes, resp.Index)
	}
	if len(indexes) != 3 || indexes[0] != 0 || indexes[1] != 1 || indexes[2] != 2 {
		t.Fatalf("indexes = %v", indexes)
	}
}
