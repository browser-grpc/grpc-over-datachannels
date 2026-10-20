package dcwebrtc

// WebRTC-Direct: signaling-free client->server connections.
// The dialer needs only the listener's address + certhash (its
// libp2p multiaddr); a wrong certhash must fail the DTLS
// handshake (certificate pinning). The TURN case is the
// symmetric-NAT shape, against the shared fake TURN server.

import (
	"net"
	"strings"
	"testing"
	"time"
)

func directEchoServer(t *testing.T, listener *DirectListener, got chan<- []byte) {
	t.Helper()
	endpoint, err := listener.Accept()
	if err != nil {
		t.Errorf("direct accept: %v", err)
		return
	}
	endpoint.SetOnChannel(func(channel *DataChannel) {
		channel.OnMessage(func(data []byte, isText bool) {
			cp := append([]byte(nil), data...)
			got <- cp
			channel.Send([]byte("direct-reply"))
		})
	})
}

func directClientEcho(t *testing.T, endpoint *DcEndpoint, payload string) []byte {
	t.Helper()
	channel := endpoint.OpenChannel(DefaultChannelParams("echo"))
	got := make(chan []byte, 1)
	channel.OnMessage(func(data []byte, isText bool) {
		got <- append([]byte(nil), data...)
	})
	channel.Send([]byte(payload))
	select {
	case data := <-got:
		return data
	case <-time.After(15 * time.Second):
		t.Fatal("echo timed out")
		return nil
	}
}

func TestCerthashAndMultiaddrRoundTrip(t *testing.T) {
	cert, err := GenerateCertificate()
	if err != nil {
		t.Fatal(err)
	}
	hash := CerthashOfCert(cert)
	if !strings.HasPrefix(hash, "fEi") {
		t.Fatalf("certhash prefix: %s", hash)
	}
	digest, err := ParseCerthash(hash)
	if err != nil {
		t.Fatal(err)
	}
	if FingerprintOfDigest(digest) != cert.Fingerprint() {
		t.Fatal("fingerprint mismatch")
	}
	addr := &net.UDPAddr{IP: net.ParseIP("203.0.113.7"), Port: 4001}
	ma := DirectMultiaddr(addr, hash)
	want := "/ip4/203.0.113.7/udp/4001/webrtc-direct/certhash/" + hash
	if ma != want {
		t.Fatalf("multiaddr = %s, want %s", ma, want)
	}
	parsedAddr, parsedDigest, err := ParseDirectMultiaddr(ma)
	if err != nil {
		t.Fatal(err)
	}
	if !parsedAddr.IP.Equal(addr.IP) || parsedAddr.Port != addr.Port {
		t.Fatalf("parsed addr = %v", parsedAddr)
	}
	if string(parsedDigest) != string(digest) {
		t.Fatal("digest mismatch")
	}
	if _, err := ParseCerthash("fAAA"); err == nil {
		t.Fatal("short certhash accepted")
	}
	if _, _, err := ParseDirectMultiaddr("/ip4/1.2.3.4/tcp/4001/webrtc-direct"); err == nil {
		t.Fatal("bad multiaddr accepted")
	}
}

func TestDirectClientServerEcho(t *testing.T) {
	listener, err := NewDirectListener("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	got := make(chan []byte, 1)
	go directEchoServer(t, listener, got)

	client, err := DirectDialMultiaddr(listener.Multiaddr(), nil)
	if err != nil {
		t.Fatalf("direct dial: %v", err)
	}
	defer client.Close()
	if reply := directClientEcho(t, client, "direct-hello"); string(reply) != "direct-reply" {
		t.Fatalf("reply = %q", reply)
	}
	select {
	case data := <-got:
		if string(data) != "direct-hello" {
			t.Fatalf("server got %q", data)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server received nothing")
	}
}

func TestDirectOverTurnEcho(t *testing.T) {
	_, turnAddr := fakeTurn(t)
	listener, err := NewDirectListener("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	got := make(chan []byte, 1)
	go directEchoServer(t, listener, got)

	client, err := DirectDialTurnMultiaddr(listener.Multiaddr(), nil, TurnServerConfig{
		Address: turnAddr, Username: "dcuser", Password: "dcpass",
	})
	if err != nil {
		t.Fatalf("direct dial over TURN: %v", err)
	}
	defer client.Close()
	if reply := directClientEcho(t, client, "via-turn-direct"); string(reply) != "direct-reply" {
		t.Fatalf("reply = %q", reply)
	}
	select {
	case data := <-got:
		if string(data) != "via-turn-direct" {
			t.Fatalf("server got %q", data)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server received nothing")
	}
}

func TestDirectDialRejectsWrongCerthash(t *testing.T) {
	listener, err := NewDirectListener("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		// The client must bail during the handshake; accept may
		// fail -- either outcome is fine here.
		_, _ = listener.Accept()
	}()
	other, err := GenerateCertificate()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DirectDial(listener.Addr(), CerthashOfCert(other), nil); err == nil {
		t.Fatal("dial with wrong certhash succeeded")
	}
}
