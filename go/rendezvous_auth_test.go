package grpcdc_test

// Rendezvous auth: the fixed cross-stack token vector (the JS
// and Rust suites verify this exact token), plus accept /
// reject / expired / wrong-scope through ServeRendezvousWithAuth
// over a real rendezvous listener.

import (
	"context"
	"net"
	"testing"
	"time"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
)

const vectorSecret = "rendezvous-auth-test-secret"
const vectorToken = "CgVhbGljZRIGaXNzdWVyGgpyZW5kZXp2b3VzIICumaQPKIDiz6oGMIDiz6oGOgRyZWFkOgV3cml0ZUIFdmVjLTE.3KLgA4zxXSOPZn2jw1lNkYqm5Urijo37qwU0NVMkIWM"

func vectorAuth() *grpcdc.RendezvousAuth {
	return &grpcdc.RendezvousAuth{
		Secret:   []byte(vectorSecret),
		Issuer:   "issuer",
		Audience: "rendezvous",
		Now:      func() time.Time { return time.Unix(1700000100, 0) },
	}
}

func TestRendezvousAuthVector(t *testing.T) {
	claims, err := vectorAuth().VerifyRendezvousToken(vectorToken)
	if err != nil {
		t.Fatal(err)
	}
	if claims.Sub != "alice" || claims.Iss != "issuer" || claims.Aud != "rendezvous" ||
		claims.Exp != 4102444800 || claims.Nbf != 1700000000 || claims.Iat != 1700000000 ||
		claims.Jti != "vec-1" || len(claims.Scopes) != 2 ||
		claims.Scopes[0] != "read" || claims.Scopes[1] != "write" {
		t.Fatalf("claims = %+v", claims)
	}
	issued := grpcdc.IssueRendezvousToken([]byte(vectorSecret), claims)
	if issued != vectorToken {
		t.Fatalf("issued = %q, want the fixed vector", issued)
	}
}

func TestRendezvousAuthRejects(t *testing.T) {
	expired := vectorAuth()
	expired.Now = func() time.Time { return time.Unix(4102444800, 0) }
	if _, err := expired.VerifyRendezvousToken(vectorToken); err == nil {
		t.Fatal("expired token verified")
	}
	wrong := vectorAuth()
	wrong.Secret = []byte("wrong-secret")
	if _, err := wrong.VerifyRendezvousToken(vectorToken); err == nil {
		t.Fatal("bad-signature token verified")
	}
	if _, err := vectorAuth().VerifyRendezvousToken("not-a-token"); err == nil {
		t.Fatal("malformed token verified")
	}
}

func dialRendezvous(t *testing.T, listener *dcwebrtc.RendezvousListener) *echo.EchoClient {
	t.Helper()
	desc := listener.Descriptor("127.0.0.1")
	dialer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{
		LocalIPs: []string{"127.0.0.1"}, RequirePeerCertificate: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dialer.Close() })
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
	t.Cleanup(func() { endpoint.Close() })
	channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("grpc"))
	return echo.NewEchoClient(grpcdc.NewChannel(grpcdc.NewDcTransport(channel)))
}

func serveAuth(t *testing.T, scopes map[string][]string) (*echo.EchoClient, *grpcdc.Server) {
	t.Helper()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	auth := vectorAuth()
	auth.Scopes = scopes
	listener, err := grpcdc.ServeRendezvousWithAuth(server,
		&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0},
		dcwebrtc.RendezvousOptions{LocalIPs: []string{"127.0.0.1"}}, auth)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	return dialRendezvous(t, listener), server
}

func TestRendezvousAuthAcceptAndScope(t *testing.T) {
	client, _ := serveAuth(t, map[string][]string{"/echo.Echo/Unary": {"read"}})
	resp := &echo.EchoResponse{}
	err := client.Channel.UnaryWithMetadata(context.Background(), "/echo.Echo/Unary",
		&echo.EchoRequest{Message: "hello"}, resp,
		map[string]string{"authorization": "Bearer " + vectorToken})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello" {
		t.Fatalf("resp = %q", resp.Message)
	}
}

func TestRendezvousAuthMissingAndUnderScoped(t *testing.T) {
	client, _ := serveAuth(t, map[string][]string{"/echo.Echo/Unary": {"read"}})
	err := client.Channel.UnaryWithMetadata(context.Background(), "/echo.Echo/Unary",
		&echo.EchoRequest{Message: "hello"}, &echo.EchoResponse{}, nil)
	if err == nil || grpcdc.Status(err).Code != grpcdc.CodeUnauthenticated {
		t.Fatalf("missing token err = %v", err)
	}

	scoped, _ := serveAuth(t, map[string][]string{"/echo.Echo/Unary": {"admin"}})
	err = scoped.Channel.UnaryWithMetadata(context.Background(), "/echo.Echo/Unary",
		&echo.EchoRequest{Message: "hello"}, &echo.EchoResponse{},
		map[string]string{"authorization": "Bearer " + vectorToken})
	if err == nil || grpcdc.Status(err).Code != grpcdc.CodePermissionDenied {
		t.Fatalf("under-scoped err = %v", err)
	}
}
