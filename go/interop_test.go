package grpcdc_test

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

// Cross-language interop over the stdio bridge (same pattern as the
// Rust<->JS tests): each framed unit is exactly one DataChannel
// message. Binaries are skipped when not built.

func rustExample(t *testing.T, name string) string {
	t.Helper()
	path := filepath.Join("..", "rust", "target", "debug", "examples", name)
	if _, err := os.Stat(path); err != nil {
		t.Skipf("rust example %s not built", name)
	}
	return path
}

func TestGoClientCallsRustServer(t *testing.T) {
	proc := exec.Command(rustExample(t, "echo_server_stdio"))
	stdin, err := proc.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := proc.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	proc.Stderr = os.Stderr
	if err := proc.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = stdin.Close()
		_ = proc.Process.Kill()
		_, _ = proc.Process.Wait()
	}()

	client := echo.NewEchoClient(grpcdc.NewChannel(echo.NewStdioTransport(stdin, stdout)))
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
	var ticks []string
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		ticks = append(ticks, resp.Message)
	}
	if strings.Join(ticks, ",") != "tick,tick,tick" {
		t.Fatalf("ticks = %v", ticks)
	}

	joined, err := client.ClientStream(ctx, req("a", 0), req("b", 0), req("c", 0))
	if err != nil {
		t.Fatal(err)
	}
	if joined.Message != "a+b+c" {
		t.Fatalf("clientStream = %q", joined.Message)
	}

	bidi, err := client.Bidi(ctx, req("x", 0), req("y", 0))
	if err != nil {
		t.Fatal(err)
	}
	var echoed []string
	for {
		resp, err := bidi.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		echoed = append(echoed, resp.Message)
	}
	if strings.Join(echoed, ",") != "x,y" {
		t.Fatalf("bidi = %v", echoed)
	}

	_, err = client.Unary(ctx, req("fail", 0))
	if err == nil || !strings.Contains(err.Error(), "INVALID-ARGUMENT") {
		t.Fatalf("fail err = %v", err)
	}
}

func TestRustClientCallsGoServer(t *testing.T) {
	serverBin := filepath.Join(t.TempDir(), "echo_server_stdio")
	build := exec.Command("go", "build", "-o", serverBin, "./examples/echo_server_stdio")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build go server: %v\n%s", err, out)
	}
	server := exec.Command(serverBin)
	serverIn, err := server.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	serverOut, err := server.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	server.Stderr = os.Stderr
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = server.Process.Kill()
		_, _ = server.Process.Wait()
	}()

	client := exec.Command(rustExample(t, "echo_client_stdio"))
	clientIn, err := client.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	clientOut, err := client.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	client.Stderr = &stderr
	if err := client.Start(); err != nil {
		t.Fatal(err)
	}

	// Pipe the two processes together: client stdout -> server stdin,
	// server stdout -> client stdin.
	go func() { _, _ = io.Copy(serverIn, clientOut) }()
	go func() { _, _ = io.Copy(clientIn, serverOut) }()

	if err := client.Wait(); err != nil {
		t.Fatalf("rust client: %v\nstderr:\n%s", err, stderr.String())
	}
	out := stderr.String()
	for _, want := range []string{
		"unary=echo: hello",
		"server_stream=tick#0,tick#1,tick#2",
		"client_stream=a+b+c",
		"bidi=x,y",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in rust client output:\n%s", want, out)
		}
	}
}
