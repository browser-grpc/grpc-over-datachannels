package grpcdc_test

// Runtime registration (Go): RegisterService/UnregisterService
// after ServeTransport take effect on the next call (the
// registry is mutex-guarded; see Server.mu).

import (
	"context"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func TestRuntimeRegistration(t *testing.T) {
	clientTransport, serverTransport := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	server.ServeTransport(serverTransport)
	client := echo.NewEchoClient(grpcdc.NewChannel(clientTransport))
	req := &echo.EchoRequest{Message: "hi"}

	if _, err := client.Unary(context.Background(), req); grpcdc.Status(err).Code != grpcdc.CodeUnimplemented {
		t.Fatalf("before register: err = %v", err)
	}
	echo.RegisterEchoServer(server, echo.EchoService{})
	if got := server.RegisteredServices(); len(got) != 1 || got[0] != "echo.Echo" {
		t.Fatalf("RegisteredServices = %v", got)
	}
	resp, err := client.Unary(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hi" {
		t.Fatalf("resp = %q", resp.Message)
	}
	server.UnregisterService("echo.Echo")
	if got := server.RegisteredServices(); len(got) != 0 {
		t.Fatalf("RegisteredServices after unregister = %v", got)
	}
	if _, err := client.Unary(context.Background(), req); grpcdc.Status(err).Code != grpcdc.CodeUnimplemented {
		t.Fatalf("after unregister: err = %v", err)
	}
}
