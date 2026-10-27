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
	"encoding/base64"
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

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	testingpb "github.com/browser-grpc/grpc-over-datachannels/go/interop"
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

// ORCA out-of-band streaming (OpenRcaService): feed the shared
// OOB state via FullDuplexCall, then read it back on
// StreamCoreMetrics — against the reference Go server (whose
// ORCA service streams its recorder) and our own server.
func TestOrcaOobStream(t *testing.T) {
	feedAndRead := func(t *testing.T, client *testingpb.TestServiceClient, orca *testingpb.OpenRcaServiceClient) {
		t.Helper()
		ctx := context.Background()
		duplex, err := client.FullDuplexCall(ctx, &testingpb.StreamingOutputCallRequest{
			OrcaOobReport: &testingpb.TestOrcaReport{
				CpuUtilization:    0.9,
				MemoryUtilization: 0.85,
				Utilization:       map[string]float64{"util": 0.5},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		for {
			_, err := duplex.Recv()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
		}
		stream, err := orca.StreamCoreMetrics(ctx, &testingpb.OrcaLoadReportRequest{})
		if err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			report, err := stream.Recv()
			if err != nil {
				t.Fatal(err)
			}
			if report.CpuUtilization == 0.9 && report.MemUtilization == 0.85 &&
				report.Utilization["util"] == 0.5 {
				return
			}
		}
		t.Fatal("no matching OOB report within 30s")
	}

	t.Run("grpc-go TestServiceServer", func(t *testing.T) {
		client, channel, closeFn := interopClient(t, "go")
		defer closeFn()
		feedAndRead(t, client, testingpb.NewOpenRcaServiceClient(channel))
	})

	t.Run("our Go server (loopback)", func(t *testing.T) {
		a, b := grpcdc.MemoryTransportPair()
		server := grpcdc.NewServer()
		testingpb.RegisterTestServiceServer(server, testServiceImpl{})
		testingpb.RegisterOpenRcaServiceServer(server, openRcaServiceImpl{})
		server.ServeTransport(b)
		channel := grpcdc.NewChannel(a)
		feedAndRead(t, testingpb.NewTestServiceClient(channel),
			testingpb.NewOpenRcaServiceClient(channel))
	})
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

	t.Run("orca_per_rpc", func(t *testing.T) {
		// Upstream orca_per_rpc: the per-request TestOrcaReport
		// comes back as the serialized OrcaLoadReport in the
		// endpoint-load-metrics-bin trailer (base64 -bin value).
		stream, err := channel.UnaryStream(ctx, "/grpc.testing.TestService/UnaryCall",
			&testingpb.SimpleRequest{
				OrcaPerQueryReport: &testingpb.TestOrcaReport{
					CpuUtilization:    0.8210,
					MemoryUtilization: 0.5847,
					RequestCost:       map[string]float64{"cost": 3456.32},
					Utilization:       map[string]float64{"util": 0.30499},
				},
			}, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := stream.Recv(&testingpb.SimpleResponse{}); err != nil {
			t.Fatal(err)
		}
		if err := stream.Recv(&testingpb.SimpleResponse{}); err != io.EOF {
			t.Fatalf("final recv = %v, want EOF", err)
		}
		encoded := stream.Trailer()["endpoint-load-metrics-bin"]
		raw, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			// Servers may send raw (unpadded) base64, as grpc-go
			// does; grpc's decodeBinHeader accepts both forms.
			raw, err = base64.RawStdEncoding.DecodeString(encoded)
		}
		if err != nil {
			t.Fatalf("trailer %q: %v", encoded, err)
		}
		report := &testingpb.OrcaLoadReport{}
		if err := report.UnmarshalDC(raw); err != nil {
			t.Fatal(err)
		}
		if report.CpuUtilization != 0.8210 || report.MemUtilization != 0.5847 ||
			report.RequestCost["cost"] != 3456.32 || report.Utilization["util"] != 0.30499 {
			t.Fatalf("report = %+v", report)
		}
	})

	t.Run("client_compressed_unary", func(t *testing.T) {
		// Gzip-compressed request (grpc-encoding call metadata);
		// the reference server only accepts when the request
		// really arrives compressed (expect_compressed).
		stream, err := channel.UnaryStream(ctx, "/grpc.testing.TestService/UnaryCall",
			&testingpb.SimpleRequest{
				ExpectCompressed: &testingpb.BoolValue{Value: true},
				ResponseSize:     31415,
				Payload:          &testingpb.Payload{Body: zeros(271828)},
			}, map[string]string{"grpc-encoding": "gzip"})
		if err != nil {
			t.Fatal(err)
		}
		resp := &testingpb.SimpleResponse{}
		if err := stream.Recv(resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Payload.Body) != 31415 {
			t.Fatalf("payload len = %d", len(resp.Payload.Body))
		}
	})

	t.Run("server_compressed_unary", func(t *testing.T) {
		// The server gzip-compresses the response
		// (response_compressed); the transport decompresses, so
		// the payload arrives intact and decodable.
		resp, err := client.UnaryCall(ctx, &testingpb.SimpleRequest{
			ResponseCompressed: &testingpb.BoolValue{Value: true},
			ResponseSize:       31415,
			Payload:            &testingpb.Payload{Body: zeros(271828)},
		})
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.Payload.Body) != 31415 {
			t.Fatalf("payload len = %d", len(resp.Payload.Body))
		}
	})

	t.Run("client_compressed_streaming", func(t *testing.T) {
		sizes := []int32{27182, 8, 1828, 45904}
		reqs := make([]grpcdc.Marshaler, 0, len(sizes))
		total := 0
		for _, size := range sizes {
			reqs = append(reqs, &testingpb.StreamingInputCallRequest{
				Payload: &testingpb.Payload{Body: zeros(int(size))},
			})
			total += int(size)
		}
		resp := &testingpb.StreamingInputCallResponse{}
		err := channel.ClientStreamCallWithMetadata(ctx,
			"/grpc.testing.TestService/StreamingInputCall", reqs, resp,
			map[string]string{"grpc-encoding": "gzip"})
		if err != nil {
			t.Fatal(err)
		}
		if int(resp.AggregatedPayloadSize) != total {
			t.Fatalf("aggregated = %d, want %d", resp.AggregatedPayloadSize, total)
		}
	})

	t.Run("server_compressed_streaming", func(t *testing.T) {
		sizes := []int32{31415, 9, 2653, 58979}
		params := make([]*testingpb.ResponseParameters, 0, len(sizes))
		for _, size := range sizes {
			params = append(params, &testingpb.ResponseParameters{Size: size})
		}
		stream, err := client.StreamingOutputCall(ctx, &testingpb.StreamingOutputCallRequest{
			ResponseParameters: params,
		})
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
			if int32(len(resp.Payload.Body)) != sizes[got] {
				t.Fatalf("size[%d] = %d", got, len(resp.Payload.Body))
			}
			got++
		}
		if got != len(sizes) {
			t.Fatalf("got %d responses", got)
		}
	})

	t.Run("custom_metadata", func(t *testing.T) {
		// Upstream custom_metadata: echo-initial returns as
		// response initial metadata, echo-trailing-bin (binary
		// 0x0a 0x0b ...; base64 on our wire) as trailers.
		// Asserted on UnaryCall and FullDuplexCall, mirroring
		// AbstractInteropTest.
		trailingBin := base64.StdEncoding.EncodeToString(
			[]byte{0x0a, 0x0b, 0x0a, 0x0b, 0x0a, 0x0b})
		md := map[string]string{
			"x-grpc-test-echo-initial":       "test_initial_metadata_value",
			"x-grpc-test-echo-trailing-bin": trailingBin,
		}
		assertEcho := func(header, trailer map[string]string) {
			t.Helper()
			if got := header["x-grpc-test-echo-initial"]; got != "test_initial_metadata_value" {
				t.Fatalf("initial echo = %q", got)
			}
			if got := trailer["x-grpc-test-echo-trailing-bin"]; got != trailingBin {
				t.Fatalf("trailing echo = %q, want %q", got, trailingBin)
			}
		}

		stream, err := channel.UnaryStream(ctx, "/grpc.testing.TestService/UnaryCall",
			&testingpb.SimpleRequest{
				ResponseSize: 1,
				Payload:      &testingpb.Payload{Body: zeros(1)},
			}, md)
		if err != nil {
			t.Fatal(err)
		}
		resp := &testingpb.SimpleResponse{}
		if err := stream.Recv(resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Payload.Body) != 1 {
			t.Fatalf("payload len = %d", len(resp.Payload.Body))
		}
		if err := stream.Recv(&testingpb.SimpleResponse{}); err != io.EOF {
			t.Fatalf("final recv = %v, want EOF", err)
		}
		assertEcho(stream.Header(), stream.Trailer())

		duplex, err := channel.BidiWithMetadata(ctx, "/grpc.testing.TestService/FullDuplexCall",
			[]grpcdc.Marshaler{&testingpb.StreamingOutputCallRequest{
				ResponseParameters: []*testingpb.ResponseParameters{{Size: 1}},
				Payload:            &testingpb.Payload{Body: zeros(1)},
			}}, md)
		if err != nil {
			t.Fatal(err)
		}
		if err := duplex.Recv(&testingpb.StreamingOutputCallResponse{}); err != nil {
			t.Fatal(err)
		}
		if err := duplex.Recv(&testingpb.StreamingOutputCallResponse{}); err != io.EOF {
			t.Fatalf("duplex final recv = %v, want EOF", err)
		}
		assertEcho(duplex.Header(), duplex.Trailer())
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
