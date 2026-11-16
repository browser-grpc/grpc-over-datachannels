package grpcdc_test

// Server interceptors (Go): install order, rejection ends
// the call before the handler, context replacement reaches
// downstream.

import (
	"context"
	"sync"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

type markerKey struct{}

func TestInterceptors(t *testing.T) {
	clientTransport, serverTransport := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})

	var mu sync.Mutex
	var order []string
	server.AddInterceptor(func(ctx context.Context, info grpcdc.CallInfo) (context.Context, *grpcdc.StatusError) {
		mu.Lock()
		order = append(order, "first:"+info.Path)
		mu.Unlock()
		return context.WithValue(ctx, markerKey{}, "seen"), nil
	})
	server.AddInterceptor(func(ctx context.Context, info grpcdc.CallInfo) (context.Context, *grpcdc.StatusError) {
		mu.Lock()
		order = append(order, "second")
		mu.Unlock()
		if info.Metadata["x-block"] == "yes" {
			return ctx, grpcdc.NewStatus(grpcdc.CodeUnauthenticated, "blocked by interceptor")
		}
		return ctx, nil
	})
	server.ServeTransport(serverTransport)

	channel := grpcdc.NewChannel(clientTransport)
	client := echo.NewEchoClient(channel)
	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hi" {
		t.Fatalf("resp = %q", resp.Message)
	}
	mu.Lock()
	got := append([]string(nil), order...)
	mu.Unlock()
	if len(got) != 2 || got[0] != "first:/echo.Echo/Unary" || got[1] != "second" {
		t.Fatalf("order = %v", got)
	}

	err = channel.UnaryWithMetadata(context.Background(), "/echo.Echo/Unary",
		&echo.EchoRequest{Message: "hi"}, &echo.EchoResponse{},
		map[string]string{"x-block": "yes"})
	if err == nil || grpcdc.Status(err).Code != grpcdc.CodeUnauthenticated {
		t.Fatalf("blocked err = %v", err)
	}
}
