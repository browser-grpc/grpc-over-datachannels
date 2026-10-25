package grpcdc_test

// Interop oracle, Direction B: the OFFICIAL interop clients
// (grpc-java TestServiceClient, grpc-go interop-client) run
// the canonical cases against our generated Go TestService
// server, reached over HTTP/2 through the Node ingress proxy
// -> WebRTC-Direct (the product proxy shape). Skips when an
// oracle binary or Node is unavailable (Dockerfile.ci builds
// them).
//
// Excluded (../oracle/interop/README.md): auth, compression,
// soak. cacheable_unary runs only under the Java client
// (unsupported by the Go client).

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	grpcdc "grpcdc"
	testingpb "grpcdc/interop"
)

// testServiceImpl mirrors the reference TestServiceImpl
// semantics the interop cases grade.
type testServiceImpl struct{}

func maybeFail(req *testingpb.SimpleRequest) error {
	if st := req.ResponseStatus; st != nil && (st.Code != 0 || st.Message != "") {
		return grpcdc.NewStatus(grpcdc.Code(st.Code), st.Message)
	}
	return nil
}

// Reference echo (custom_metadata case): the echo-initial
// request value returns as initial metadata, the
// echo-trailing-bin value (base64 on our wire) as trailers.
func echoMetadata(ctx context.Context) {
	md := grpcdc.MetadataFromContext(ctx)
	if v, ok := md["x-grpc-test-echo-initial"]; ok {
		grpcdc.SetHeader(ctx, map[string]string{"x-grpc-test-echo-initial": v})
	}
	if v, ok := md["x-grpc-test-echo-trailing-bin"]; ok {
		grpcdc.SetTrailer(ctx, map[string]string{"x-grpc-test-echo-trailing-bin": v})
	}
}

func unaryResponse(req *testingpb.SimpleRequest) (*testingpb.SimpleResponse, error) {
	if err := maybeFail(req); err != nil {
		return nil, err
	}
	return &testingpb.SimpleResponse{
		Payload: &testingpb.Payload{Type: req.ResponseType, Body: make([]byte, req.ResponseSize)},
	}, nil
}

func (testServiceImpl) EmptyCall(ctx context.Context, req *testingpb.Empty) (*testingpb.Empty, error) {
	echoMetadata(ctx)
	return &testingpb.Empty{}, nil
}

// ORCA load reporting (orca_per_rpc / orca_oob): a per-request
// TestOrcaReport rides back as the serialized OrcaLoadReport in
// the endpoint-load-metrics-bin trailer (base64, as -bin values
// travel); OOB reports carried by FullDuplexCall requests update
// shared state that later UnaryCalls report.
var orcaOobMu sync.Mutex
var orcaOobReport *testingpb.OrcaLoadReport

func setOrcaTrailer(ctx context.Context, report *testingpb.OrcaLoadReport) {
	grpcdc.SetTrailer(ctx, map[string]string{
		"endpoint-load-metrics-bin": base64.StdEncoding.EncodeToString(report.MarshalDC()),
	})
}

func (testServiceImpl) UnaryCall(ctx context.Context, req *testingpb.SimpleRequest) (*testingpb.SimpleResponse, error) {
	echoMetadata(ctx)
	if r := req.OrcaPerQueryReport; r != nil {
		setOrcaTrailer(ctx, &testingpb.OrcaLoadReport{
			CpuUtilization: r.CpuUtilization,
			MemUtilization: r.MemoryUtilization,
			RequestCost:    r.RequestCost,
			Utilization:    r.Utilization,
		})
	} else {
		orcaOobMu.Lock()
		oob := orcaOobReport
		orcaOobMu.Unlock()
		if oob != nil {
			setOrcaTrailer(ctx, oob)
		}
	}
	return unaryResponse(req)
}

func (testServiceImpl) CacheableUnaryCall(ctx context.Context, req *testingpb.SimpleRequest) (*testingpb.SimpleResponse, error) {
	echoMetadata(ctx)
	// Reference semantics: echo the request payload.
	if err := maybeFail(req); err != nil {
		return nil, err
	}
	return &testingpb.SimpleResponse{Payload: req.Payload}, nil
}

func sendResponses(req *testingpb.StreamingOutputCallRequest, send func(*testingpb.StreamingOutputCallResponse) error) error {
	if st := req.ResponseStatus; st != nil && (st.Code != 0 || st.Message != "") {
		return grpcdc.NewStatus(grpcdc.Code(st.Code), st.Message)
	}
	for i, param := range req.ResponseParameters {
		if i > 0 && param.IntervalUs > 0 {
			time.Sleep(time.Duration(param.IntervalUs) * time.Microsecond)
		}
		resp := &testingpb.StreamingOutputCallResponse{
			Payload: &testingpb.Payload{Type: req.ResponseType, Body: make([]byte, param.Size)},
		}
		if err := send(resp); err != nil {
			return err
		}
	}
	return nil
}

func (testServiceImpl) StreamingOutputCall(req *testingpb.StreamingOutputCallRequest, stream testingpb.TestServiceStreamingOutputCallServer) error {
	echoMetadata(stream.Context())
	return sendResponses(req, stream.Send)
}

func (testServiceImpl) StreamingInputCall(stream testingpb.TestServiceStreamingInputCallServer) error {
	echoMetadata(stream.Context())
	total := 0
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return stream.SendAndClose(&testingpb.StreamingInputCallResponse{
				AggregatedPayloadSize: int32(total),
			})
		}
		if err != nil {
			return err
		}
		if req.Payload != nil {
			total += len(req.Payload.Body)
		}
	}
}

func (testServiceImpl) FullDuplexCall(stream testingpb.TestServiceFullDuplexCallServer) error {
	echoMetadata(stream.Context())
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if r := req.OrcaOobReport; r != nil {
			orcaOobMu.Lock()
			orcaOobReport = &testingpb.OrcaLoadReport{
				CpuUtilization: r.CpuUtilization,
				MemUtilization: r.MemoryUtilization,
				Utilization:    r.Utilization,
			}
			orcaOobMu.Unlock()
		}
		if err := sendResponses(req, stream.Send); err != nil {
			return err
		}
	}
}

func (testServiceImpl) HalfDuplexCall(stream testingpb.TestServiceHalfDuplexCallServer) error {
	echoMetadata(stream.Context())
	var reqs []*testingpb.StreamingOutputCallRequest
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		reqs = append(reqs, req)
	}
	for _, req := range reqs {
		if err := sendResponses(req, stream.Send); err != nil {
			return err
		}
	}
	return nil
}

func (testServiceImpl) UnimplementedCall(ctx context.Context, req *testingpb.Empty) (*testingpb.Empty, error) {
	return nil, grpcdc.NewStatus(grpcdc.CodeUnimplemented, "not implemented")
}

var interopCasesB = []string{
	"empty_unary",
	"large_unary",
	"client_streaming",
	"server_streaming",
	"ping_pong",
	"empty_stream",
	"custom_metadata",
	"status_code_and_message",
	"special_status_message",
	"unimplemented_method",
	"unimplemented_service",
	"cancel_after_begin",
	"cancel_after_first_response",
	"timeout_on_sleeping_server",
}

// ORCA cases run only under the Go client (with the upstream
// test LB service config): grpc-java's TestServiceClient fails
// them even against the upstream Go interop server.
var orcaCasesB = []string{"orca_per_rpc", "orca_oob"}

// startGoServerBehindProxy serves the Go TestService over
// WebRTC-Direct and starts the Node ingress proxy in front of
// it; returns the HTTP/2 port official clients dial.
func startGoServerBehindProxy(t *testing.T) int {
	t.Helper()
	listener, err := grpcdc.DirectListener("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	server := grpcdc.NewServer()
	testingpb.RegisterTestServiceServer(server, testServiceImpl{})
	go func() {
		transport, err := grpcdc.AcceptDirectTransport(listener)
		if err != nil {
			return
		}
		server.ServeTransport(transport)
	}()

	http2Port := freePort(t)
	proxy := exec.Command("node", filepath.Join("..", "proxy", "grpc-dc-proxy.mjs"),
		"--dc-dial", listener.Multiaddr(), "--http2", fmt.Sprint(http2Port))
	proxy.Stdout = os.Stderr
	proxy.Stderr = os.Stderr
	if err := proxy.Start(); err != nil {
		t.Skipf("node ingress proxy unavailable: %v", err)
	}
	t.Cleanup(func() { _ = proxy.Process.Kill() })
	deadline := time.Now().Add(60 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", http2Port), time.Second)
		if err == nil {
			_ = conn.Close()
			return http2Port
		}
		if time.Now().After(deadline) {
			t.Fatal("ingress proxy did not start")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestInteropOfficialClientsCallGoServer(t *testing.T) {
	port := startGoServerBehindProxy(t)

	t.Run("grpc-go client", func(t *testing.T) {
		binary := filepath.Join("..", "oracle", "go-interop", "interop-client")
		if _, err := os.Stat(binary); err != nil {
			t.Skip("go interop client not built")
		}
		for _, testCase := range append(append([]string{}, interopCasesB...), orcaCasesB...) {
			t.Run(testCase, func(t *testing.T) {
				args := []string{"-server_host", "127.0.0.1", "-server_port", fmt.Sprint(port),
					"-test_case", testCase}
				if strings.HasPrefix(testCase, "orca") {
					args = append(args, "-service_config_json",
						`{ "loadBalancingConfig": [{ "test_backend_metrics_load_balancer": {} }]}`)
				}
				out, err := exec.Command(binary, args...).CombinedOutput()
				if err != nil {
					t.Fatalf("case %s: %v\n%s", testCase, err, out)
				}
			})
		}
	})

	t.Run("grpc-java client", func(t *testing.T) {
		cp := javaClasspath(t)
		for _, testCase := range append(append([]string{}, interopCasesB...), "cacheable_unary") {
			t.Run(testCase, func(t *testing.T) {
				out, err := exec.Command("java", "-cp", cp,
					"io.grpc.testing.integration.TestServiceClient",
					"--server_host=127.0.0.1", fmt.Sprintf("--server_port=%d", port),
					"--test_case="+testCase, "--use_tls=false").CombinedOutput()
				if err != nil {
					t.Fatalf("case %s: %v\n%s", testCase, err, out)
				}
				if !strings.Contains(string(out), "Test completed.") {
					t.Fatalf("case %s: unexpected output\n%s", testCase, out)
				}
			})
		}
	})
}
