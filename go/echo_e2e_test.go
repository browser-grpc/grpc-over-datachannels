package grpcdc_test

import (
	"context"
	"errors"
	"io"
	"testing"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func req(message string, count int32) *echo.EchoRequest {
	return &echo.EchoRequest{Message: message, Count: count}
}

func setup(t *testing.T) *echo.EchoClient {
	t.Helper()
	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)
	return echo.NewEchoClient(grpcdc.NewChannel(a))
}

func TestEchoAllShapesLoopback(t *testing.T) {
	client := setup(t)
	ctx := context.Background()

	unary, err := client.Unary(ctx, req("hello", 0))
	if err != nil {
		t.Fatal(err)
	}
	if unary.Message != "echo: hello" {
		t.Fatalf("unary = %q", unary.Message)
	}

	stream, err := client.ServerStream(ctx, req("tick", 3))
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

	joined, err := client.ClientStream(ctx, req("a", 0), req("b", 0), req("c", 0))
	if err != nil {
		t.Fatal(err)
	}
	if joined.Message != "a+b+c" || joined.Index != 3 {
		t.Fatalf("clientStream = %+v", joined)
	}

	bidi, err := client.Bidi(ctx, req("x", 0), req("y", 0))
	if err != nil {
		t.Fatal(err)
	}
	var echoed []string
	for {
		resp, err := bidi.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		echoed = append(echoed, resp.Message)
	}
	if len(echoed) != 2 || echoed[0] != "x" || echoed[1] != "y" {
		t.Fatalf("bidi = %v", echoed)
	}
}

func TestHandlerErrorPropagatesAsStatus(t *testing.T) {
	client := setup(t)
	_, err := client.Unary(context.Background(), req("fail", 0))
	var status *grpcdc.StatusError
	if !errors.As(err, &status) || status.Code != grpcdc.CodeInvalidArgument {
		t.Fatalf("err = %v, want INVALID-ARGUMENT StatusError", err)
	}
	if status.Message != "asked to fail" {
		t.Fatalf("message = %q", status.Message)
	}
}

func TestConcurrentStreams(t *testing.T) {
	client := setup(t)
	ctx := context.Background()
	done := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() {
			resp, err := client.Unary(ctx, req("hello", 0))
			if err == nil && resp.Message != "echo: hello" {
				err = errors.New("bad message: " + resp.Message)
			}
			done <- err
		}()
	}
	for i := 0; i < 8; i++ {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}
