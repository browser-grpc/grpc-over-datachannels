package dcwebrtc

// WebRTC-Direct: signaling-free client->server connections.
// The dialer needs only the listener's address + certhash (its
// libp2p multiaddr); a wrong certhash must fail the DTLS
// handshake (certificate pinning). The TURN case is the
// symmetric-NAT shape, against the shared fake TURN server.

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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

// Four dialers handshake concurrently against one listener
// (one Accept goroutine each): every payload must reach its
// own endpoint, proving the listener demultiplexes by peer
// address instead of letting endpoints steal each other's
// handshake packets.
func TestDirectConcurrentDialers(t *testing.T) {
	listener, err := NewDirectListener("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	got := make(chan []byte, 4)
	for i := 0; i < 4; i++ {
		go directEchoServer(t, listener, got)
	}
	replies := make(chan string, 4)
	for i := 0; i < 4; i++ {
		go func(i int) {
			client, err := DirectDialMultiaddr(listener.Multiaddr(), nil)
			if err != nil {
				t.Errorf("concurrent dial %d: %v", i, err)
				replies <- ""
				return
			}
			defer client.Close()
			payload := "hello-" + string(rune('0'+i))
			if reply := directClientEcho(t, client, payload); string(reply) != "direct-reply" {
				t.Errorf("reply %d = %q", i, reply)
			}
			replies <- payload
		}(i)
	}
	seen := map[string]bool{}
	for i := 0; i < 4; i++ {
		select {
		case data := <-got:
			seen[string(data)] = true
		case <-time.After(15 * time.Second):
			t.Fatal("server received fewer than 4 payloads")
		}
	}
	for i := 0; i < 4; i++ {
		<-replies
		if !seen["hello-"+string(rune('0'+i))] {
			t.Fatalf("missing payload hello-%d in %v", i, seen)
		}
	}
}

// Direct over TURN with a 3 s allocation lifetime enforced by
// the fake: traffic must still flow after 5 s, which is only
// possible if the dialer's Peer refresher re-issues Refresh
// (and permissions/channel binds) before expiry.
func TestDirectOverTurnRefreshPastLifetime(t *testing.T) {
	fake, turnAddr := fakeTurnWith(t, 3, 3)
	listener, err := NewDirectListener("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	got := make(chan []byte, 2)
	go directEchoServer(t, listener, got)

	client, err := DirectDialTurnMultiaddr(listener.Multiaddr(), nil, TurnServerConfig{
		Address: turnAddr, Username: "dcuser", Password: "dcpass",
	})
	if err != nil {
		t.Fatalf("direct dial over TURN: %v", err)
	}
	defer client.Close()
	channel := client.OpenChannel(DefaultChannelParams("echo"))
	replies := make(chan []byte, 2)
	channel.OnMessage(func(data []byte, isText bool) {
		replies <- append([]byte(nil), data...)
	})
	channel.Send([]byte("via-turn-direct"))
	select {
	case data := <-replies:
		if string(data) != "direct-reply" {
			t.Fatalf("reply = %q", data)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("first echo timed out")
	}
	// Past the 3 s lifetime: the fake drops relayed traffic for
	// expired allocations, so this second echo only works if
	// the allocation was refreshed in the background.
	time.Sleep(5 * time.Second)
	channel.Send([]byte("after-expiry"))
	select {
	case data := <-replies:
		if string(data) != "direct-reply" {
			t.Fatalf("reply after expiry = %q", data)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("echo after allocation lifetime timed out (refresh missing?)")
	}
	if refreshes, _ := fake.Stats(); refreshes < 1 {
		t.Fatalf("refreshes = %d, want >= 1", refreshes)
	}
	for _, want := range []string{"via-turn-direct", "after-expiry"} {
		select {
		case data := <-got:
			if string(data) != want {
				t.Fatalf("server got %q, want %q", data, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("server never received %q", want)
		}
	}
}

// ---------------------------------------------------------------------------
// Real-coturn legs: TURNS (TLS client<->server transport) and
// IPv6. Skipped when turnserver (or openssl) is unavailable;
// Dockerfile.ci installs both, so CI always runs these legs.
// ---------------------------------------------------------------------------

// coturn takes a numeric port, so the port is probe-close
// allocated: bind(0), read the allocated port, close, and let
// coturn rebind it. The race is covered by verifying the
// child survived startup and retrying on a fresh port when
// it did not.
func spawnCoturn(t *testing.T, extra func(port int) []string) (string, func()) {
	t.Helper()
	if _, err := exec.LookPath("turnserver"); err != nil {
		t.Skip("turnserver not on PATH")
	}
	for attempt := 0; attempt < 3; attempt++ {
		probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
		if err != nil {
			t.Fatal(err)
		}
		port := probe.LocalAddr().(*net.UDPAddr).Port
		_ = probe.Close()
		args := append([]string{"-n", "--realm=dc.test", "--user=dcuser:dcpass",
			"--lt-cred-mech", "--allow-loopback-peers", "--no-cli"}, extra(port)...)
		cmd := exec.Command("turnserver", args...)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		exited := make(chan error, 1)
		go func() { exited <- cmd.Wait() }()
		select {
		case <-exited:
			continue // did not survive startup; fresh port
		case <-time.After(800 * time.Millisecond):
		}
		stop := func() {
			_ = cmd.Process.Kill()
			<-exited
		}
		return strconv.Itoa(port), stop
	}
	t.Fatal("turnserver did not survive startup after 3 attempts")
	return "", nil
}

func coturnEcho(t *testing.T, listenerAddr, turnAddr string, cfg TurnServerConfig, payload string) {
	t.Helper()
	listener, err := NewDirectListener(listenerAddr, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	got := make(chan []byte, 1)
	go directEchoServer(t, listener, got)
	cfg.Address = turnAddr
	var client *DcEndpoint
	var lastErr error
	for i := 0; i < 10 && client == nil; i++ {
		client, lastErr = DirectDialTurnMultiaddr(listener.Multiaddr(), nil, cfg)
		if client == nil {
			time.Sleep(500 * time.Millisecond)
		}
	}
	if client == nil {
		t.Fatalf("direct dial over coturn: %v", lastErr)
	}
	defer client.Close()
	if reply := directClientEcho(t, client, payload); string(reply) != "direct-reply" {
		t.Fatalf("reply = %q", reply)
	}
	select {
	case data := <-got:
		if string(data) != payload {
			t.Fatalf("server got %q", data)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server received nothing")
	}
}

func TestDirectOverTurnsCoturn(t *testing.T) {
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Skip("openssl not on PATH")
	}
	dir := t.TempDir()
	cert, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	cmd := exec.Command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
		"-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("openssl cert failed: %v (%s)", err, out)
	}
	_ = os.Chmod(key, 0o600)
	port, stop := spawnCoturn(t, func(port int) []string {
		return []string{"--listening-ip=127.0.0.1", "--relay-ip=127.0.0.1",
			"--tls-listening-port=" + strconv.Itoa(port),
			"--cert=" + cert, "--pkey=" + key}
	})
	defer stop()
	coturnEcho(t, "127.0.0.1:0", "127.0.0.1:"+port, TurnServerConfig{
		Username: "dcuser", Password: "dcpass",
		Transport: "tls", InsecureSkipVerify: true,
	}, "via-turns")
}

func TestDirectOverTurnIPv6Coturn(t *testing.T) {
	if _, err := net.ListenUDP("udp6", &net.UDPAddr{IP: net.ParseIP("::1")}); err != nil {
		t.Skip("no IPv6 loopback")
	}
	port, stop := spawnCoturn(t, func(port int) []string {
		return []string{"--listening-ip=::1", "--listening-port=" + strconv.Itoa(port),
			"--relay-ip=::1"}
	})
	defer stop()
	coturnEcho(t, "[::1]:0", "[::1]:"+port, TurnServerConfig{
		Username: "dcuser", Password: "dcpass", RequestIPv6Relay: true,
	}, "via-ipv6-turn")
}
