package grpcdc_test

// IPC transports (Go): Echo over a Unix domain socket via
// DialUds (host/plugin seam), and the stream transport over
// an in-memory pipe pair.

import (
	"context"
	"io"
	"net"
	"path/filepath"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func TestIpcUdsEcho(t *testing.T) {
	path := filepath.Join(t.TempDir(), "plugin.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		server := grpcdc.NewServer()
		echo.RegisterEchoServer(server, echo.EchoService{})
		server.ServeTransport(grpcdc.NewSidecarTransport(conn))
	}()

	transport, err := grpcdc.DialUds(path)
	if err != nil {
		t.Fatal(err)
	}
	defer transport.Close()
	client := echo.NewEchoClient(grpcdc.NewChannel(transport))
	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello-ipc"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello-ipc" {
		t.Fatalf("resp = %q", resp.Message)
	}
}

func TestIpcStreamTransportEcho(t *testing.T) {
	r1, w1 := io.Pipe()
	r2, w2 := io.Pipe()
	serverTransport := grpcdc.NewStreamTransport(r1, w2)
	clientTransport := grpcdc.NewStreamTransport(r2, w1)
	go func() {
		server := grpcdc.NewServer()
		echo.RegisterEchoServer(server, echo.EchoService{})
		server.ServeTransport(serverTransport)
	}()
	client := echo.NewEchoClient(grpcdc.NewChannel(clientTransport))
	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello-stdio"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello-stdio" {
		t.Fatalf("resp = %q", resp.Message)
	}
}
