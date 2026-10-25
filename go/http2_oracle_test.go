package grpcdc_test

// HTTP/2 oracle tests: the generated Go client calls the official
// grpc-java server DIRECTLY over HTTP/2 (no bridge). http2.go is
// generated code (manual HPACK + HTTP/2
// session from RFC tables). The TLS case dials a Node TLS HTTP/2
// front-end fixture (stdlib TLS + ALPN h2 both sides) backed by
// a JS Echo server. Skips when the Java oracle or Node are
// unavailable (Dockerfile.ci provides both).

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func TestHttp2GoClientCallsOfficialServer(t *testing.T) {
	javaPort := freePort(t)
	startJavaServer(t, javaPort)

	transport, err := grpcdc.DialHttp2(fmt.Sprintf("127.0.0.1:%d", javaPort), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	channel := grpcdc.NewChannel(transport)
	client := echo.NewEchoClient(channel)
	runOracleScenarios(t, client)

	// Metadata reflected by the oracle (x-echo suffix).
	metaResp := &echo.EchoResponse{}
	err = channel.UnaryWithMetadata(context.Background(), "/echo.Echo/Unary",
		&echo.EchoRequest{Message: "meta"}, metaResp, map[string]string{"x-echo": "go-http2"})
	if err != nil {
		t.Fatal(err)
	}
	if metaResp.Message != "echo: meta [go-http2]" {
		t.Fatalf("metadata echo = %q", metaResp.Message)
	}

	// Flow control: 200-message stream and a 300 KiB message.
	stream, err := client.ServerStream(context.Background(), &echo.EchoRequest{Message: "big", Count: 200})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for {
		if _, err := stream.Recv(); err != nil {
			break
		}
		n++
	}
	if n != 200 {
		t.Fatalf("stream count = %d, want 200", n)
	}
	bigResp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: strings.Repeat("x", 300000)})
	if err != nil {
		t.Fatal(err)
	}
	if len(bigResp.Message) != 300006 {
		t.Fatalf("big resp len = %d", len(bigResp.Message))
	}
}

func TestHttp2GoClientTLS(t *testing.T) {
	fixture := filepath.Join("..", "js", "test", "http2_tls_fixture.mjs")
	cmd := exec.Command("node", fixture)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Skipf("node unavailable: %v", err)
	}
	defer func() { _ = cmd.Process.Kill() }()
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil || !strings.HasPrefix(line, "READY") {
		t.Skipf("TLS fixture did not start: %q %v", line, err)
	}
	fields := strings.Fields(line)
	port, _ := strconv.Atoi(fields[1])
	certPEM, err := os.ReadFile(fields[2])
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(certPEM) {
		t.Fatal("fixture cert not appended")
	}
	transport, err := grpcdc.DialHttp2(fmt.Sprintf("localhost:%d", port),
		&tls.Config{RootCAs: pool, ServerName: "localhost"})
	if err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	client := echo.NewEchoClient(grpcdc.NewChannel(transport))
	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello" {
		t.Fatalf("resp = %q", resp.Message)
	}
}
