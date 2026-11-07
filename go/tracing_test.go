package grpcdc_test

// Tracing: a registered Tracer observes one shared trace id
// with the server span parented to the client span; dormant
// (and span-free) without one.

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

type traceEnd struct {
	kind       string
	method     string
	traceID    string
	spanID     string
	status     string
	durationMs float64
}

type traceRecorder struct {
	mu     sync.Mutex
	starts [][5]string
	ends   []traceEnd
}

func (r *traceRecorder) OnStart(kind, method, traceID, spanID, parentSpanID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.starts = append(r.starts, [5]string{kind, method, traceID, spanID, parentSpanID})
}

func (r *traceRecorder) OnEnd(kind, method, traceID, spanID, status string, durationMs float64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.ends = append(r.ends, traceEnd{kind, method, traceID, spanID, status, durationMs})
}

func TestTracing(t *testing.T) {
	rec := &traceRecorder{}
	grpcdc.SetTracer(rec)
	defer grpcdc.SetTracer(nil)

	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)
	client := echo.NewEchoClient(grpcdc.NewChannel(a))

	if _, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello"}); err != nil {
		t.Fatal(err)
	}

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.starts) != 2 || len(rec.ends) != 2 {
		t.Fatalf("starts=%v ends=%v", rec.starts, rec.ends)
	}
	var clientSpan, serverSpan [5]string
	for _, s := range rec.starts {
		switch s[0] {
		case "client":
			clientSpan = s
		case "server":
			serverSpan = s
		}
	}
	if clientSpan[2] == "" || clientSpan[2] != serverSpan[2] {
		t.Fatalf("trace ids differ: client %v server %v", clientSpan, serverSpan)
	}
	if serverSpan[4] != clientSpan[3] {
		t.Fatalf("server parent %q != client span %q", serverSpan[4], clientSpan[3])
	}
	for _, e := range rec.ends {
		if e.status != "OK" || e.durationMs < 0 {
			t.Fatalf("end %+v", e)
		}
	}
}

type frontService struct {
	echo.EchoService
	downstream *echo.EchoClient
	seenSpanID string
}

func (f *frontService) Unary(ctx context.Context, req *echo.EchoRequest) (*echo.EchoResponse, error) {
	if tc := grpcdc.TraceContextFromContext(ctx); tc != nil {
		f.seenSpanID = tc.SpanID
	}
	return f.downstream.Unary(ctx, &echo.EchoRequest{Message: "nested"})
}

func TestTracingNestedCalleeCall(t *testing.T) {
	rec := &traceRecorder{}
	grpcdc.SetTracer(rec)
	defer grpcdc.SetTracer(nil)

	a2, b2 := grpcdc.MemoryTransportPair()
	back := grpcdc.NewServer()
	echo.RegisterEchoServer(back, echo.EchoService{})
	back.ServeTransport(b2)
	front := &frontService{downstream: echo.NewEchoClient(grpcdc.NewChannel(a2))}

	a, b := grpcdc.MemoryTransportPair()
	frontServer := grpcdc.NewServer()
	echo.RegisterEchoServer(frontServer, front)
	frontServer.ServeTransport(b)
	client := echo.NewEchoClient(grpcdc.NewChannel(a))

	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: nested" {
		t.Fatalf("response %q", resp.Message)
	}

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.starts) != 4 || len(rec.ends) != 4 {
		t.Fatalf("starts=%v ends=%v", rec.starts, rec.ends)
	}
	kinds := []string{rec.starts[0][0], rec.starts[1][0], rec.starts[2][0], rec.starts[3][0]}
	if fmt.Sprint(kinds) != "[client server client server]" {
		t.Fatalf("kinds %v", kinds)
	}
	outerClient, outerServer, innerClient, innerServer :=
		rec.starts[0], rec.starts[1], rec.starts[2], rec.starts[3]
	for _, s := range rec.starts {
		if s[2] != outerClient[2] {
			t.Fatalf("trace ids differ: %v", rec.starts)
		}
	}
	if outerServer[4] != outerClient[3] || innerClient[4] != outerServer[3] ||
		innerServer[4] != innerClient[3] {
		t.Fatalf("parent chain broken: %v", rec.starts)
	}
	if front.seenSpanID != outerServer[3] {
		t.Fatalf("handler ctx span %q != server span %q", front.seenSpanID, outerServer[3])
	}
	for _, e := range rec.ends {
		if e.durationMs < 0 {
			t.Fatalf("end %+v", e)
		}
	}
}

func TestTracingRootContextGroupsCalls(t *testing.T) {
	rec := &traceRecorder{}
	grpcdc.SetTracer(rec)
	defer grpcdc.SetTracer(nil)

	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)
	client := echo.NewEchoClient(grpcdc.NewChannel(a))

	root := grpcdc.NewTraceContext("internal", "workflow")
	if root == nil {
		t.Fatal("root context is nil")
	}
	ctx := grpcdc.ContextWithTraceContext(context.Background(), root)
	for _, msg := range []string{"one", "two"} {
		if _, err := client.Unary(ctx, &echo.EchoRequest{Message: msg}); err != nil {
			t.Fatal(err)
		}
	}
	grpcdc.EndTraceContext(root, "OK")

	rec.mu.Lock()
	defer rec.mu.Unlock()
	clients := 0
	for _, s := range rec.starts {
		if s[2] != root.TraceID {
			t.Fatalf("span outside root trace: %v", s)
		}
		if s[0] == "client" {
			clients++
			if s[4] != root.SpanID {
				t.Fatalf("client span parent %q != root %q", s[4], root.SpanID)
			}
		}
	}
	if clients != 2 {
		t.Fatalf("client spans %d", clients)
	}
}

func TestTracingNotSampled(t *testing.T) {
	parent := grpcdc.ParseTraceparent(
		"00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00")
	if parent == nil || parent.Sampled {
		t.Fatalf("parent %+v", parent)
	}
	if got := grpcdc.FormatTraceparent(parent.TraceID, parent.SpanID,
		parent.Sampled); !strings.HasSuffix(got, "-00") {
		t.Fatalf("traceparent %q", got)
	}

	rec := &traceRecorder{}
	grpcdc.SetTracer(rec)
	defer grpcdc.SetTracer(nil)

	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)
	channel := grpcdc.NewChannel(a)
	var resp echo.EchoResponse
	err := channel.UnaryWithMetadata(context.Background(), "/echo.Echo/Unary",
		&echo.EchoRequest{Message: "hello"}, &resp,
		map[string]string{
			"traceparent": "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-00",
		})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello" {
		t.Fatalf("response %q", resp.Message)
	}

	rec.mu.Lock()
	defer rec.mu.Unlock()
	if len(rec.starts) != 0 || len(rec.ends) != 0 {
		t.Fatalf("starts=%v ends=%v", rec.starts, rec.ends)
	}
}
