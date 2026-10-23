package grpcdc_test

// Deadlines: context deadlines propagate as grpc-timeout and are
// enforced in ClientStream.Recv (CodeDeadlineExceeded + RST); the
// server handler context carries the remaining budget.

import (
	"context"
	"io"
	"testing"
	"time"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

type slowEcho struct {
	echo.EchoService
	ctxCh chan context.Context
}

func (s *slowEcho) Unary(ctx context.Context, req *echo.EchoRequest) (*echo.EchoResponse, error) {
	select {
	case s.ctxCh <- ctx:
	default:
	}
	time.Sleep(400 * time.Millisecond)
	return s.EchoService.Unary(ctx, req)
}

func (s *slowEcho) ServerStream(req *echo.EchoRequest, stream echo.EchoServerStreamServer) error {
	for i := int32(0); i < req.Count; i++ {
		if i > 0 {
			time.Sleep(300 * time.Millisecond)
		}
		if err := stream.Send(&echo.EchoResponse{Message: req.Message, Index: i}); err != nil {
			return err
		}
	}
	return nil
}

func setupSlow(t *testing.T) (*echo.EchoClient, *slowEcho) {
	t.Helper()
	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	svc := &slowEcho{ctxCh: make(chan context.Context, 1)}
	echo.RegisterEchoServer(server, svc)
	server.ServeTransport(b)
	return echo.NewEchoClient(grpcdc.NewChannel(a)), svc
}

func TestTimeoutCodecRoundTrip(t *testing.T) {
	for _, d := range []time.Duration{250 * time.Millisecond, 90 * time.Second} {
		got, ok := grpcdc.ParseTimeout(grpcdc.EncodeTimeout(d))
		if !ok || got != d {
			t.Fatalf("round trip %v: got %v ok=%v", d, got, ok)
		}
	}
	if _, ok := grpcdc.ParseTimeout("10x"); ok {
		t.Fatal("junk parsed")
	}
}

func TestUnaryDeadlineExceeded(t *testing.T) {
	client, svc := setupSlow(t)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := client.Unary(ctx, req("hello", 0))
	var st *grpcdc.StatusError
	if err == nil {
		t.Fatal("expected deadline error")
	}
	st, _ = err.(*grpcdc.StatusError)
	if st == nil || st.Code != grpcdc.CodeDeadlineExceeded {
		t.Fatalf("err = %v", err)
	}
	if elapsed := time.Since(start); elapsed > 350*time.Millisecond {
		t.Fatalf("deadline took %v", elapsed)
	}
	var seenCtx context.Context
	select {
	case seenCtx = <-svc.ctxCh:
	case <-time.After(2 * time.Second):
		t.Fatal("handler never ran")
	}
	if _, ok := seenCtx.Deadline(); !ok {
		t.Fatal("server ctx has no deadline")
	}
	if grpcdc.MetadataFromContext(seenCtx)["grpc-timeout"] == "" {
		t.Fatal("grpc-timeout metadata missing")
	}
}

func TestServerStreamDeadlineMidStream(t *testing.T) {
	client, _ := setupSlow(t)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	stream, err := client.ServerStream(ctx, req("tick", 5))
	if err != nil {
		t.Fatal(err)
	}
	first, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if first.Index != 0 {
		t.Fatalf("first index %d", first.Index)
	}
	_, err = stream.Recv()
	if err == io.EOF || err == nil {
		t.Fatalf("expected deadline error, got %v", err)
	}
	if st, _ := err.(*grpcdc.StatusError); st == nil || st.Code != grpcdc.CodeDeadlineExceeded {
		t.Fatalf("err = %v", err)
	}
}

func TestContextCancelGivesCancelled(t *testing.T) {
	client, _ := setupSlow(t)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	_, err := client.Unary(ctx, req("hello", 0))
	if st, _ := err.(*grpcdc.StatusError); st == nil || st.Code != grpcdc.CodeCancelled {
		t.Fatalf("err = %v", err)
	}
}
