package grpcdc_test

import (
	"context"
	"errors"
	"io"
	"sync/atomic"
	"testing"
	"time"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

// BDD: interprets the generated behavior scenarios
// (bdd_scenarios_generated_test.go, generated from
// the BDD specification; prose in BDD.md) against a loopback
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
	runBddScenarios(t, channel, client)
}

func runBddScenarios(t *testing.T, channel *grpcdc.Channel, client *echo.EchoClient) {
	ctx := context.Background()
	for _, c := range bddCases {
		t.Run(c.name, func(t *testing.T) {
			switch c.kind {
			case "unary-trailer":
				stream, err := channel.UnaryStream(ctx, "/echo.Echo/Unary", req(c.messages[0], 0),
					map[string]string{"x-echo-trailer": c.metadata})
				if err != nil {
					t.Fatal(err)
				}
				resp := new(echo.EchoResponse)
				if err := stream.Recv(resp); err != nil {
					t.Fatal(err)
				}
				if err := stream.Recv(new(echo.EchoResponse)); err != io.EOF {
					t.Fatalf("final recv = %v, want EOF", err)
				}
				if resp.Message != c.expectMessage || int(resp.Index) != c.expectNum {
					t.Fatalf("resp = %v, want %q/%d", resp, c.expectMessage, c.expectNum)
				}
				if got := stream.Trailer()["x-echo-trailer"]; got != c.metadata {
					t.Fatalf("trailer x-echo-trailer = %q, want %q", got, c.metadata)
				}
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
			case "server-stream-fail":
				stream, err := client.ServerStream(ctx, req(c.messages[0], int32(c.count)))
				if err != nil {
					t.Fatal(err)
				}
				for {
					_, err := stream.Recv()
					if err != nil {
						var status *grpcdc.StatusError
						if !errors.As(err, &status) || int(status.Code) != c.expectStatus {
							t.Fatalf("err = %v, want status %d", err, c.expectStatus)
						}
						break
					}
				}
			case "bidi-fail":
				reqs := make([]*echo.EchoRequest, len(c.messages))
				for i, m := range c.messages {
					reqs[i] = req(m, 0)
				}
				stream, err := client.Bidi(ctx, reqs...)
				if err != nil {
					t.Fatal(err)
				}
				for {
					_, err := stream.Recv()
					if err != nil {
						var status *grpcdc.StatusError
						if !errors.As(err, &status) || int(status.Code) != c.expectStatus {
							t.Fatalf("err = %v, want status %d", err, c.expectStatus)
						}
						break
					}
				}
			case "deadline":
				dctx, stop := context.WithTimeout(ctx, 100*time.Millisecond)
				_, err := client.Unary(dctx, &echo.EchoRequest{Message: c.messages[0], DelayMs: int32(c.count)})
				stop()
				var status *grpcdc.StatusError
				if !errors.As(err, &status) || int(status.Code) != c.expectStatus {
					t.Fatalf("err = %v, want status %d", err, c.expectStatus)
				}
			case "stream-break":
				// Dedicated counting server: abandoning the
				// stream (ctx cancel, no further Recv) must RST
				// it so production stops.
				produced := &atomic.Int32{}
				ta, tb := grpcdc.MemoryTransportPair()
				breakServer := grpcdc.NewServer()
				echo.RegisterEchoServer(breakServer, countingStreamService{produced: produced})
				breakServer.ServeTransport(tb)
				breakClient := echo.NewEchoClient(grpcdc.NewChannel(ta))
				cctx, cancelCall := context.WithCancel(ctx)
				stream, err := breakClient.ServerStream(cctx, req(c.messages[0], int32(c.count)))
				if err != nil {
					t.Fatal(err)
				}
				first, err := stream.Recv()
				if err != nil || first.Message != c.messages[0] {
					t.Fatalf("first = %v, err = %v", first, err)
				}
				cancelCall()
				time.Sleep(150 * time.Millisecond)
				settled := produced.Load()
				time.Sleep(150 * time.Millisecond)
				if got := produced.Load(); got != settled {
					t.Fatalf("server kept producing after break: %d -> %d", settled, got)
				}
				if settled >= 50 {
					t.Fatalf("server produced %d, want stopped early", settled)
				}
			case "cancel":
				cctx, cancelCall := context.WithCancel(ctx)
				stream, err := client.ServerStream(cctx, req(c.messages[0], int32(c.count)))
				if err != nil {
					t.Fatal(err)
				}
				first, err := stream.Recv()
				if err != nil || first.Message != c.messages[0] {
					t.Fatalf("first = %v, err = %v", first, err)
				}
				cancelCall()
				terminated := false
				for i := 0; i < c.count+2 && !terminated; i++ {
					if _, err := stream.Recv(); err != nil {
						terminated = true
					}
				}
				if !terminated {
					t.Fatal("stream did not terminate after cancel")
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
