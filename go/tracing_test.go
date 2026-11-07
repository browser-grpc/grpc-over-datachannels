package grpcdc_test

// Tracing: a registered Tracer observes one shared trace id
// with the server span parented to the client span; dormant
// (and span-free) without one.

import (
	"context"
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
