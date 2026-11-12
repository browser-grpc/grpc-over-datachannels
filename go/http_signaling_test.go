package grpcdc_test

// HTTP/POST signaling (grpcdc.ServeHttpSignaling): a Go Peer
// offerer POSTs its offer, the generated signaling server
// answers and serves Echo on the resulting "grpc" DataChannel.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
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
	signaling, err := grpcdc.NewHttpSignalingServer(server, grpcdc.HttpSignalingOptions{
		PeerOptions: dcwebrtc.PeerOptions{LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer signaling.Close()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	httpServer := &http.Server{Handler: signaling.Handler}
	go func() { _ = httpServer.Serve(listener) }()
	defer httpServer.Close()
	url := "http://" + listener.Addr().String() + "/grpc-dc/signal"

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
		Type    string `json:"type"`
		SDP     string `json:"sdp"`
		Session string `json:"session"`
	}
	if err := json.NewDecoder(res.Body).Decode(&answer); err != nil {
		t.Fatal(err)
	}
	if answer.Type != "answer" || !strings.Contains(answer.SDP, "a=setup:active") {
		t.Fatalf("answer = %+v", answer)
	}
	// Every session peer lives on the server's one shared
	// PeerMux socket: the answer's candidates carry its port.
	if !strings.Contains(answer.SDP, fmt.Sprintf(" %d typ host", signaling.Mux.LocalAddr().Port)) {
		t.Fatalf("answer candidates do not use the mux port %d: %s", signaling.Mux.LocalAddr().Port, answer.SDP)
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

	// Trickle + restart over the answer's session id.
	if answer.Session == "" {
		t.Fatal("answer carries no session id")
	}
	if lines := offererPeer.LocalCandidateLines(); len(lines) > 0 {
		candidateBody, _ := json.Marshal(map[string]string{
			"session": answer.Session, "candidate": strings.TrimPrefix(lines[0], "a="),
		})
		candRes, err := http.Post(url+"/candidate", "application/json", bytes.NewReader(candidateBody))
		if err != nil {
			t.Fatal(err)
		}
		candRes.Body.Close()
		if candRes.StatusCode != http.StatusOK {
			t.Fatalf("candidate status = %d", candRes.StatusCode)
		}
	}
	restartBody, _ := json.Marshal(map[string]string{
		"session": answer.Session, "type": "offer", "sdp": offererPeer.CreateRestartOffer(),
	})
	restartRes, err := http.Post(url+"/restart", "application/json", bytes.NewReader(restartBody))
	if err != nil {
		t.Fatal(err)
	}
	defer restartRes.Body.Close()
	if restartRes.StatusCode != http.StatusOK {
		t.Fatalf("restart status = %d", restartRes.StatusCode)
	}
	var restartAnswer struct {
		SDP string `json:"sdp"`
	}
	if err := json.NewDecoder(restartRes.Body).Decode(&restartAnswer); err != nil {
		t.Fatal(err)
	}
	if err := offererPeer.HandleRestartAnswer(restartAnswer.SDP); err != nil {
		t.Fatal(err)
	}
	after, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "after"})
	if err != nil {
		t.Fatal(err)
	}
	if after.Message != "echo: after" {
		t.Fatalf("after restart unary = %q", after.Message)
	}
}
