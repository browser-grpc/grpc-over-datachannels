package grpcdc_test

import (
	"bytes"
	"context"
	"io"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
	testingpb "github.com/browser-grpc/grpc-over-datachannels/go/interop"
)

func setupStruct(t *testing.T, clientStruct, serverStruct bool) *echo.EchoClient {
	t.Helper()
	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	server.SetStructCodec(serverStruct)
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)
	ch := grpcdc.NewChannel(a)
	ch.SetStructCodec(clientStruct)
	return echo.NewEchoClient(ch)
}

func TestStructCodecEchoRoundtrip(t *testing.T) {
	client := setupStruct(t, true, true)
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
	n := 0
	for {
		_, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
	if n != 3 {
		t.Fatalf("streamed %d responses, want 3", n)
	}

	joined, err := client.ClientStream(ctx, req("a", 0), req("b", 0))
	if err != nil {
		t.Fatal(err)
	}
	if joined.Message != "a+b" {
		t.Fatalf("clientStream = %+v", joined)
	}

	bidi, err := client.Bidi(ctx, req("x", 0), req("y", 0))
	if err != nil {
		t.Fatal(err)
	}
	n = 0
	for {
		_, err := bidi.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		n++
	}
	if n != 2 {
		t.Fatalf("bidi echoed %d, want 2", n)
	}
}

func TestStructCodecNegotiation(t *testing.T) {
	ctx := context.Background()

	// Struct client against a protobuf-only server: the
	// explicit marker must fail UNIMPLEMENTED, never misparse.
	structClient := setupStruct(t, true, false)
	_, err := structClient.Unary(ctx, req("hello", 0))
	if status := grpcdc.Status(err); status == nil || status.Code != grpcdc.CodeUnimplemented {
		t.Fatalf("struct client vs plain server: err = %v, want UNIMPLEMENTED", err)
	}

	// Plain client against a struct-enabled server: no marker,
	// protobuf default still works.
	plainClient := setupStruct(t, false, true)
	resp, err := plainClient.Unary(ctx, req("hello", 0))
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello" {
		t.Fatalf("plain client vs struct server: %q", resp.Message)
	}
}

func TestStructCodecTranscode(t *testing.T) {
	req := &testingpb.SimpleRequest{
		ResponseType: testingpb.PayloadType_COMPRESSABLE,
		ResponseSize: 1024,
		Payload: &testingpb.Payload{
			Type: testingpb.PayloadType_COMPRESSABLE,
			Body: bytes.Repeat([]byte{0xAB}, 4096),
		},
		FillUsername: true,
		FillServerId: true,
	}
	st := req.MarshalStructDC()
	if !bytes.HasPrefix(st, []byte("DCS1")) {
		t.Fatal("struct encoding missing magic")
	}
	var back testingpb.SimpleRequest
	if err := back.UnmarshalStructDC(st); err != nil {
		t.Fatal(err)
	}
	if back.ResponseSize != req.ResponseSize || !bytes.Equal(back.Payload.Body, req.Payload.Body) {
		t.Fatalf("struct roundtrip mismatch: %+v", back)
	}
	// struct -> protobuf -> struct must be byte-stable.
	var fromPb testingpb.SimpleRequest
	if err := fromPb.UnmarshalDC(back.MarshalDC()); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(st, fromPb.MarshalStructDC()) {
		t.Fatal("transcode roundtrip differs")
	}
	// Truncated struct input errors instead of panicking.
	if err := back.UnmarshalStructDC(st[:8]); err == nil {
		t.Fatal("expected error on truncated struct input")
	}
}
