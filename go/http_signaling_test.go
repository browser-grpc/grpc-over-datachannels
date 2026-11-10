package grpcdc_test

// HTTP/POST signaling (grpcdc.ServeHttpSignaling): a Go Peer
// offerer POSTs its offer, the generated signaling server
// answers and serves Echo on the resulting "grpc" DataChannel.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
)

func TestHttpSignalingEcho(t *testing.T) {
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	httpServer, err := grpcdc.ServeHttpSignaling("127.0.0.1:0", server, grpcdc.HttpSignalingOptions{
		PeerOptions: dcwebrtc.PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer httpServer.Close()
	url := "http://" + httpServer.Addr + "/grpc-dc/signal"

	// Contract negatives: wrong method, malformed offer.
	getRes, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	getRes.Body.Close()
	if getRes.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET status = %d", getRes.StatusCode)
	}
	badRes, err := http.Post(url, "application/json", strings.NewReader(`{"type":"offer","sdp":""}`))
	if err != nil {
		t.Fatal(err)
	}
	badRes.Body.Close()
	if badRes.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad offer status = %d", badRes.StatusCode)
	}

	offererPeer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{
		LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer offererPeer.Close()

	offerBody, _ := json.Marshal(map[string]string{"type": "offer", "sdp": offererPeer.CreateOffer()})
	res, err := http.Post(url, "application/json", bytes.NewReader(offerBody))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("POST status = %d", res.StatusCode)
	}
	var answer struct {
		Type string `json:"type"`
		SDP  string `json:"sdp"`
	}
	if err := json.NewDecoder(res.Body).Decode(&answer); err != nil {
		t.Fatal(err)
	}
	if answer.Type != "answer" || !strings.Contains(answer.SDP, "a=setup:active") {
		t.Fatalf("answer = %+v", answer)
	}
	if err := offererPeer.HandleAnswer(answer.SDP); err != nil {
		t.Fatal(err)
	}
	endpoint, err := offererPeer.ConnectWithOptions(true)
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
