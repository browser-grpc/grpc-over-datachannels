package grpcdc_test

// Interop oracle: the generated Go client runs the canonical
// grpc interop cases (grpc.testing.TestService, vendored in
// ../oracle/interop) against the OFFICIAL TestServiceServers —
// grpc-java and grpc-go — no bridge, direct HTTP/2
// (DialHttp2). Case semantics mirror grpc's
// AbstractInteropTest. Skips when an oracle is not built
// (Dockerfile.ci builds both).
//
// custom_metadata asserts the unary path succeeds; initial
// response metadata is asserted in the Python driver (trailing
// metadata is not surfaced by the grpc-dc frame layer — see
// ../oracle/interop/README.md).

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	grpcdc "grpcdc"
	testingpb "grpcdc/interop"
)

func startGoTestServiceServer(t *testing.T, port int) {
	t.Helper()
	binary := filepath.Join("..", "oracle", "go-interop", "interop-server")
	if _, err := os.Stat(binary); err != nil {
		t.Skip("go interop server not built (cd oracle/go-interop && go build -o interop-server google.golang.org/grpc/interop/server)")
	}
	cmd := exec.Command(binary, "-port", fmt.Sprint(port))
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start go TestServiceServer: %v", err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	// The Go server prints no readiness line; poll the TCP port.
	deadline := time.Now().Add(30 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
		if err == nil {
			_ = conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("go TestServiceServer did not start")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func startTestServiceServer(t *testing.T, port int) {
	t.Helper()
	cp := javaClasspath(t)
	cmd := exec.Command("java", "-cp", cp,
		"io.grpc.testing.integration.TestServiceServer",
		fmt.Sprintf("--port=%d", port), "--use_tls=false")
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start TestServiceServer: %v", err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	ready := make(chan struct{})
	var once sync.Once
	scan := func(r io.Reader) {
		buf := make([]byte, 4096)
		for {
			n, err := r.Read(buf)
			if n > 0 && bytes.Contains(buf[:n], []byte("Server started")) {
				once.Do(func() { close(ready) })
			}
			if err != nil {
				return
			}
		}
	}
	go scan(stderr)
	go scan(stdout)
	select {
	case <-ready:
	case <-time.After(30 * time.Second):
		t.Fatal("TestServiceServer did not start")
	}
}

func interopClient(t *testing.T, kind string) (*testingpb.TestServiceClient, *grpcdc.Channel, func()) {
	t.Helper()
	port := freePort(t)
	if kind == "go" {
		startGoTestServiceServer(t, port)
	} else {
		startTestServiceServer(t, port)
	}
	transport, err := grpcdc.DialHttp2(fmt.Sprintf("127.0.0.1:%d", port), nil)
	if err != nil {
		t.Fatal(err)
	}
	channel := grpcdc.NewChannel(transport)
	return testingpb.NewTestServiceClient(channel), channel, func() { _ = transport.Close() }
}

func zeros(n int) []byte { return make([]byte, n) }

func statusCode(err error) (grpcdc.Code, bool) {
	var se *grpcdc.StatusError
	if errors.As(err, &se) {
		return se.Code, true
	}
	return 0, false
}

func TestInteropGoClientCallsJavaTestService(t *testing.T) {
	client, channel, closeFn := interopClient(t, "java")
	defer closeFn()
	runInteropCases(t, client, channel)
}

func TestInteropGoClientCallsGoTestService(t *testing.T) {
	client, channel, closeFn := interopClient(t, "go")
	defer closeFn()
	runInteropCases(t, client, channel)
}

func runInteropCases(t *testing.T, client *testingpb.TestServiceClient, channel *grpcdc.Channel) {
	ctx := context.Background()

	t.Run("empty_unary", func(t *testing.T) {
		if _, err := client.EmptyCall(ctx, &testingpb.Empty{}); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("large_unary", func(t *testing.T) {
		resp, err := client.UnaryCall(ctx, &testingpb.SimpleRequest{
			ResponseSize: 314159,
			Payload:      &testingpb.Payload{Body: zeros(271828)},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.Payload.Body) != 314159 || !bytes.Equal(resp.Payload.Body, zeros(314159)) {
			t.Fatalf("payload len = %d", len(resp.Payload.Body))
		}
	})

	t.Run("client_streaming", func(t *testing.T) {
		sizes := []int{27182, 8, 1828, 45904}
		reqs := make([]*testingpb.StreamingInputCallRequest, len(sizes))
		want := 0
		for i, s := range sizes {
			reqs[i] = &testingpb.StreamingInputCallRequest{Payload: &testingpb.Payload{Body: zeros(s)}}
			want += s
		}
		resp, err := client.StreamingInputCall(ctx, reqs...)
		if err != nil {
			t.Fatal(err)
		}
		if int(resp.AggregatedPayloadSize) != want {
			t.Fatalf("aggregated = %d, want %d", resp.AggregatedPayloadSize, want)
		}
	})

	t.Run("server_streaming", func(t *testing.T) {
		sizes := []int32{31415, 9, 2653, 58979}
		params := make([]*testingpb.ResponseParameters, len(sizes))
		for i, s := range sizes {
			params[i] = &testingpb.ResponseParameters{Size: s}
		}
		stream, err := client.StreamingOutputCall(ctx, &testingpb.StreamingOutputCallRequest{ResponseParameters: params})
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range sizes {
			resp, err := stream.Recv()
			if err != nil {
				t.Fatal(err)
			}
			if int32(len(resp.Payload.Body)) != want {
				t.Fatalf("payload len = %d, want %d", len(resp.Payload.Body), want)
			}
		}
		if _, err := stream.Recv(); err != io.EOF {
			t.Fatalf("final recv err = %v, want EOF", err)
		}
	})

	t.Run("ping_pong", func(t *testing.T) {
		respSizes := []int{31415, 9, 2653, 58979}
		reqSizes := []int{27182, 8, 1828, 45904}
		reqs := make([]*testingpb.StreamingOutputCallRequest, len(respSizes))
		for i := range respSizes {
			reqs[i] = &testingpb.StreamingOutputCallRequest{
				ResponseParameters: []*testingpb.ResponseParameters{{Size: int32(respSizes[i])}},
				Payload:            &testingpb.Payload{Body: zeros(reqSizes[i])},
			}
		}
		stream, err := client.FullDuplexCall(ctx, reqs...)
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range respSizes {
			resp, err := stream.Recv()
			if err != nil {
				t.Fatal(err)
			}
			if len(resp.Payload.Body) != want {
				t.Fatalf("payload len = %d, want %d", len(resp.Payload.Body), want)
			}
		}
	})

	t.Run("empty_stream", func(t *testing.T) {
		stream, err := client.FullDuplexCall(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := stream.Recv(); err != io.EOF {
			t.Fatalf("recv err = %v, want EOF", err)
		}
	})

	t.Run("custom_metadata", func(t *testing.T) {
		resp := &testingpb.SimpleResponse{}
		err := channel.UnaryWithMetadata(ctx, "/grpc.testing.TestService/UnaryCall",
			&testingpb.SimpleRequest{
				ResponseSize: 1,
				Payload:      &testingpb.Payload{Body: zeros(1)},
			}, resp, map[string]string{
				"x-grpc-test-echo-initial": "test_initial_metadata_value",
			})
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.Payload.Body) != 1 {
			t.Fatalf("payload len = %d", len(resp.Payload.Body))
		}
	})

	t.Run("status_code_and_message", func(t *testing.T) {
		_, err := client.UnaryCall(ctx, &testingpb.SimpleRequest{
			ResponseStatus: &testingpb.EchoStatus{Code: 2, Message: "test status message"},
		})
		code, ok := statusCode(err)
		if !ok || code != grpcdc.CodeUnknown {
			t.Fatalf("err = %v, want code UNKNOWN", err)
		}
	})

	t.Run("special_status_message", func(t *testing.T) {
		msg := "\t\ntest with whitespace\r\nand Unicode BMP ☺ and non-BMP 😈\t\n"
		_, err := client.UnaryCall(ctx, &testingpb.SimpleRequest{
			ResponseStatus: &testingpb.EchoStatus{Code: 2, Message: msg},
		})
		var se *grpcdc.StatusError
		if !errors.As(err, &se) || se.Code != grpcdc.CodeUnknown || se.Message != msg {
			t.Fatalf("err = %v, want UNKNOWN %q", err, msg)
		}
	})

	t.Run("unimplemented_method", func(t *testing.T) {
		unimpl := testingpb.NewUnimplementedServiceClient(channel)
		_, err := unimpl.UnimplementedCall(ctx, &testingpb.Empty{})
		code, ok := statusCode(err)
		if !ok || code != grpcdc.CodeUnimplemented {
			t.Fatalf("err = %v, want UNIMPLEMENTED", err)
		}
	})

	t.Run("unimplemented_service", func(t *testing.T) {
		err := channel.Unary(ctx, "/grpc.testing.UnimplementedService2/UnimplementedCall",
			&testingpb.Empty{}, &testingpb.Empty{})
		code, ok := statusCode(err)
		if !ok || code != grpcdc.CodeUnimplemented {
			t.Fatalf("err = %v, want UNIMPLEMENTED", err)
		}
	})

	t.Run("cancel_after_begin", func(t *testing.T) {
		// interval_us keeps the server mid-stream so the cancel
		// (not a completed trailers) deterministically ends it.
		stream, err := channel.ServerStream(ctx, "/grpc.testing.TestService/StreamingOutputCall",
			&testingpb.StreamingOutputCallRequest{
				ResponseParameters: []*testingpb.ResponseParameters{
					{Size: 31415, IntervalUs: 500000},
					{Size: 31415, IntervalUs: 500000},
				},
			})
		if err != nil {
			t.Fatal(err)
		}
		stream.Cancel()
		var err2 error
		for err2 == nil {
			err2 = stream.Recv(&testingpb.StreamingOutputCallResponse{})
		}
		code, ok := statusCode(err2)
		if !ok || code != grpcdc.CodeCancelled {
			t.Fatalf("err = %v, want CANCELLED", err2)
		}
	})

	t.Run("cancel_after_first_response", func(t *testing.T) {
		// Server-streaming with intervals: after the first
		// response the server is still mid-stream, so the
		// cancel deterministically ends the call CANCELLED.
		stream, err := channel.ServerStream(ctx, "/grpc.testing.TestService/StreamingOutputCall",
			&testingpb.StreamingOutputCallRequest{
				ResponseParameters: []*testingpb.ResponseParameters{
					{Size: 31415},
					{Size: 31415, IntervalUs: 500000},
					{Size: 31415, IntervalUs: 500000},
				},
			})
		if err != nil {
			t.Fatal(err)
		}
		resp := &testingpb.StreamingOutputCallResponse{}
		if err := stream.Recv(resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Payload.Body) != 31415 {
			t.Fatalf("payload len = %d", len(resp.Payload.Body))
		}
		stream.Cancel()
		var err2 error
		for err2 == nil {
			err2 = stream.Recv(&testingpb.StreamingOutputCallResponse{})
		}
		code, ok := statusCode(err2)
		if !ok || code != grpcdc.CodeCancelled {
			t.Fatalf("err = %v, want CANCELLED", err2)
		}
	})

	t.Run("timeout_on_sleeping_server", func(t *testing.T) {
		// Server sleeps 1s between streamed responses
		// (interval_us); a 100ms client deadline must trip
		// DEADLINE_EXCEEDED mid-stream, deterministically.
		deadlineCtx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
		defer cancel()
		stream, err := client.StreamingOutputCall(deadlineCtx, &testingpb.StreamingOutputCallRequest{
			ResponseParameters: []*testingpb.ResponseParameters{
				{Size: 1, IntervalUs: 1000000},
				{Size: 1, IntervalUs: 1000000},
				{Size: 1, IntervalUs: 1000000},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		var err2 error
		for err2 == nil {
			_, err2 = stream.Recv()
		}
		code, ok := statusCode(err2)
		if !ok || code != grpcdc.CodeDeadlineExceeded {
			t.Fatalf("err = %v, want DEADLINE_EXCEEDED", err2)
		}
	})
}
