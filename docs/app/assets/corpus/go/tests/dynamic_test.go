package grpcdc_test

// Dynamic (descriptor-driven) runtime: schemas consumed as data at
// runtime, no generated stubs. Loopback plus the official grpc-java
// oracle in both directions.

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

const dynamicService = "echo.Echo"

func dynamicModel(t *testing.T) *grpcdc.FileModel {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "fixtures", "echo_descriptor_set.bin"))
	if err != nil {
		t.Skipf("descriptor fixture missing (make generate): %v", err)
	}
	model, err := grpcdc.ParseDescriptorSet(data)
	if err != nil {
		t.Fatal(err)
	}
	return model
}

func dynamicReq(model *grpcdc.FileModel, message string, count int64) *grpcdc.GenericMessage {
	return grpcdc.NewGenericMessage(model.Messages[".echo.EchoRequest"]).
		Set(1, message).Set(2, count)
}

func dynamicReqStrings(model *grpcdc.FileModel, messages []string) []*grpcdc.GenericMessage {
	reqs := make([]*grpcdc.GenericMessage, len(messages))
	for i, m := range messages {
		reqs[i] = dynamicReq(model, m, 0)
	}
	return reqs
}

func runDynamicScenarios(t *testing.T, client *grpcdc.DynamicClient, model *grpcdc.FileModel) {
	t.Helper()
	ctx := context.Background()
	for _, c := range oracleScenarios {
		line := fmt.Sprintf("%s %v", c.kind, c.messages)
		messages := make([]string, len(c.messages))
		for i, m := range c.messages {
			messages[i] = oracleUnmsg(m)
		}
		switch c.kind {
		case "UNARY":
			resp, err := client.Unary(ctx, dynamicService, "Unary", dynamicReq(model, messages[0], 0), nil)
			if c.expectStatus >= 0 {
				var status *grpcdc.StatusError
				if err == nil || !errorAsStatus(err, &status) || int(status.Code) != c.expectStatus {
					t.Errorf("%s: err = %v, want status %d", line, err, c.expectStatus)
				}
				continue
			}
			if err != nil {
				t.Fatalf("%s: %v", line, err)
			}
			if resp.GetString(1) != "echo: "+messages[0] || resp.GetInt(2) != 0 {
				t.Errorf("%s: resp = %+v", line, resp.Values)
			}
		case "SERVER_STREAM":
			stream, err := client.ServerStream(ctx, dynamicService, "ServerStream", dynamicReq(model, messages[0], int64(c.count)), nil)
			if err != nil {
				t.Fatalf("%s: %v", line, err)
			}
			var got int64
			for {
				resp, err := stream.Recv()
				if err == io.EOF {
					break
				}
				if err != nil {
					t.Fatalf("%s: %v", line, err)
				}
				if resp.GetString(1) != messages[0] || resp.GetInt(2) != got {
					t.Errorf("%s: resp = %+v at %d", line, resp.Values, got)
				}
				got++
			}
			if got != int64(c.count) {
				t.Errorf("%s: got %d responses, want %d", line, got, c.count)
			}
		case "CLIENT_STREAM":
			resp, err := client.ClientStream(ctx, dynamicService, "ClientStream", dynamicReqStrings(model, messages), nil)
			if err != nil {
				t.Fatalf("%s: %v", line, err)
			}
			joined := messages[0]
			for _, m := range messages[1:] {
				joined += "+" + m
			}
			if resp.GetString(1) != joined || resp.GetInt(2) != int64(len(messages)) {
				t.Errorf("%s: resp = %+v", line, resp.Values)
			}
		case "BIDI":
			stream, err := client.Bidi(ctx, dynamicService, "Bidi", dynamicReqStrings(model, messages), nil)
			if err != nil {
				t.Fatalf("%s: %v", line, err)
			}
			var got int64
			for {
				resp, err := stream.Recv()
				if err == io.EOF {
					break
				}
				if err != nil {
					t.Fatalf("%s: %v", line, err)
				}
				if int(got) >= len(messages) || resp.GetString(1) != messages[got] || resp.GetInt(2) != got {
					t.Errorf("%s: resp = %+v at %d", line, resp.Values, got)
				}
				got++
			}
			if got != int64(len(messages)) {
				t.Errorf("%s: got %d responses, want %d", line, got, len(messages))
			}
		}
	}
}

func errorAsStatus(err error, target **grpcdc.StatusError) bool {
	for err != nil {
		if status, ok := err.(*grpcdc.StatusError); ok {
			*target = status
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

func TestDynamicLoopback(t *testing.T) {
	model := dynamicModel(t)
	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	if err := grpcdc.RegisterDynamicService(server, model, dynamicService, echo.DynamicEchoService{}); err != nil {
		t.Fatal(err)
	}
	server.ServeTransport(b)
	client := grpcdc.NewDynamicClient(grpcdc.NewChannel(a), model)
	runDynamicScenarios(t, client, model)

	// Generic codec round-trip against the golden protobuf vector.
	modelType := model.Messages[".echo.EchoRequest"]
	encoded, err := grpcdc.EncodeGeneric(modelType, dynamicReq(model, "hi", 2), model)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprintf("%x", encoded) != "0a0268691002" {
		t.Fatalf("encoded = %x", encoded)
	}

	// Unknown fields (99 varint, 100 string) are retained verbatim.
	payload := []byte{0x0a, 0x02, 'h', 'i', 0x10, 0x02, 0x98, 0x06, 0x2a, 0xa2, 0x06, 0x01, 'x'}
	decoded, err := grpcdc.DecodeGeneric(modelType, payload, model)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Unknown) != 2 {
		t.Fatalf("unknown retained = %d chunks", len(decoded.Unknown))
	}
	roundTrip, err := grpcdc.EncodeGeneric(modelType, decoded, model)
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprintf("%x", roundTrip) != fmt.Sprintf("%x", payload) {
		t.Fatalf("round trip = %x, want %x", roundTrip, payload)
	}
}

func TestDynamicOracleClientCallsOfficialServer(t *testing.T) {
	model := dynamicModel(t)
	javaPort := freePort(t)
	startJavaServer(t, javaPort)

	bridge := exec.Command("node", filepath.Join("..", "oracle", "bridge.mjs"),
		"dc-to-http2", "--grpc", fmt.Sprintf("127.0.0.1:%d", javaPort))
	bridgeIn, err := bridge.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	bridgeOut, err := bridge.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	bridge.Stderr = os.Stderr
	if err := bridge.Start(); err != nil {
		t.Skipf("cannot start bridge: %v", err)
	}
	t.Cleanup(func() { _ = bridge.Process.Kill() })

	client := grpcdc.NewDynamicClient(
		grpcdc.NewChannel(echo.NewStdioTransport(bridgeIn, bridgeOut)), model)
	runDynamicScenarios(t, client, model)
}

func TestDynamicOracleOfficialClientCallsDynamicServer(t *testing.T) {
	serverBin := filepath.Join(t.TempDir(), "dynamic_echo_server_stdio")
	build := exec.Command("go", "build", "-o", serverBin, "./examples/dynamic_echo_server_stdio")
	if out, err := build.CombinedOutput(); err != nil {
		t.Skipf("build dynamic server: %v\n%s", err, out)
	}
	port := freePort(t)
	bridge := exec.Command("node", filepath.Join("..", "oracle", "bridge.mjs"),
		"http2-to-dc", "--port", fmt.Sprint(port), "--target-cmd", serverBin)
	bridge.Stderr = os.Stderr
	if err := bridge.Start(); err != nil {
		t.Skipf("cannot start bridge: %v", err)
	}
	t.Cleanup(func() { _ = bridge.Process.Kill() })

	runJavaClient(t, port)
}
