package grpcdc_test

import (
	"context"
	"errors"
	"io"
	"testing"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

// BDD: interprets the generated behavior scenarios
// (bdd_scenarios_generated_test.go, stamped from
// racket/bdd-spec.rkt; prose in BDD.md) against a loopback
// client+server — the executable examples.

func bddSetup(t *testing.T) (*grpcdc.Channel, *echo.EchoClient) {
	t.Helper()
	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)
	channel := grpcdc.NewChannel(a)
	return channel, echo.NewEchoClient(channel)
}

func TestBdd(t *testing.T) {
	channel, client := bddSetup(t)
	ctx := context.Background()
	for _, c := range bddCases {
		t.Run(c.name, func(t *testing.T) {
			switch c.kind {
			case "unary":
				var resp *echo.EchoResponse
				var err error
				if c.metadata != "" {
					r := new(echo.EchoResponse)
					err = channel.UnaryWithMetadata(ctx, "/echo.Echo/Unary", req(c.messages[0], 0), r,
						map[string]string{"x-echo": c.metadata})
					resp = r
				} else {
					resp, err = client.Unary(ctx, req(c.messages[0], 0))
				}
				if c.expectStatus >= 0 {
					var status *grpcdc.StatusError
					if !errors.As(err, &status) || int(status.Code) != c.expectStatus {
						t.Fatalf("err = %v, want status %d", err, c.expectStatus)
					}
					return
				}
				if err != nil {
					t.Fatal(err)
				}
				if resp.Message != c.expectMessage || int(resp.Index) != c.expectNum {
					t.Fatalf("resp = %v, want %q/%d", resp, c.expectMessage, c.expectNum)
				}
			case "server-stream":
				stream, err := client.ServerStream(ctx, req(c.messages[0], int32(c.count)))
				if err != nil {
					t.Fatal(err)
				}
				got := 0
				for {
					resp, err := stream.Recv()
					if err == io.EOF {
						break
					}
					if err != nil {
						t.Fatal(err)
					}
					if resp.Message != c.expectMessage || int(resp.Index) != got {
						t.Fatalf("resp = %v at %d", resp, got)
					}
					got++
				}
				if got != c.expectNum {
					t.Fatalf("got %d, want %d", got, c.expectNum)
				}
			case "client-stream":
				reqs := make([]*echo.EchoRequest, len(c.messages))
				for i, m := range c.messages {
					reqs[i] = req(m, 0)
				}
				resp, err := client.ClientStream(ctx, reqs...)
				if err != nil {
					t.Fatal(err)
				}
				if resp.Message != c.expectMessage || int(resp.Index) != c.expectNum {
					t.Fatalf("resp = %v", resp)
				}
			case "bidi":
				reqs := make([]*echo.EchoRequest, len(c.messages))
				for i, m := range c.messages {
					reqs[i] = req(m, 0)
				}
				stream, err := client.Bidi(ctx, reqs...)
				if err != nil {
					t.Fatal(err)
				}
				got := 0
				for {
					resp, err := stream.Recv()
					if err == io.EOF {
						break
					}
					if err != nil {
						t.Fatal(err)
					}
					if got >= len(c.messages) || resp.Message != c.messages[got] || int(resp.Index) != got {
						t.Fatalf("resp = %v at %d", resp, got)
					}
					got++
				}
				if got != c.expectNum {
					t.Fatalf("got %d, want %d", got, c.expectNum)
				}
			case "raw-unary":
				resp := new(echo.EchoResponse)
				err := channel.Unary(ctx, c.path, req(c.messages[0], 0), resp)
				var status *grpcdc.StatusError
				if !errors.As(err, &status) || int(status.Code) != c.expectStatus {
					t.Fatalf("err = %v, want status %d", err, c.expectStatus)
				}
			default:
				t.Fatalf("unknown bdd kind: %s", c.kind)
			}
		})
	}
}
