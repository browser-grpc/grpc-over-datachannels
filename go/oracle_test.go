package grpcdc_test

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

// Oracle tests: the official grpc-java implementation, bridged over
// TCP<->DataChannel by ../oracle/bridge.mjs, must agree with the Go
// runtime on every case of ../fixtures/oracle_scenarios.txt. Skips
// when the Java oracle or Node bridge are unavailable (Dockerfile.ci
// provides both).

func javaClasspath(t *testing.T) string {
	t.Helper()
	dir := filepath.Join("..", "oracle", "java", "target")
	cpFile := filepath.Join(dir, "cp.txt")
	raw, err := os.ReadFile(cpFile)
	if err != nil {
		t.Skip("java oracle not built (cd oracle/java && mvn package)")
	}
	if _, err := os.Stat(filepath.Join(dir, "classes")); err != nil {
		t.Skip("java oracle classes missing")
	}
	return filepath.Join(dir, "classes") + ":" + strings.TrimSpace(string(raw))
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func startJavaServer(t *testing.T, port int) {
	t.Helper()
	cp := javaClasspath(t)
	cmd := exec.Command("java", "-cp", cp, "dc.oracle.OracleServer", fmt.Sprint(port))
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start java oracle server: %v", err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	buf := make([]byte, 4096)
	ready := make(chan struct{})
	go func() {
		for {
			n, err := stderr.Read(buf)
			if err != nil || strings.Contains(string(buf[:n]), "READY") {
				close(ready)
				return
			}
		}
	}()
	select {
	case <-ready:
	case <-cmdDone(cmd):
		t.Fatal("java oracle server exited during startup")
	}
}

func cmdDone(cmd *exec.Cmd) chan struct{} {
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	return done
}

func runJavaClient(t *testing.T, port int) {
	t.Helper()
	cp := javaClasspath(t)
	cmd := exec.Command("java", "-cp", cp, "dc.oracle.OracleClient",
		fmt.Sprint(port), filepath.Join("..", "fixtures", "oracle_scenarios.txt"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("oracle client: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "ORACLE CLIENT: ALL OK") {
		t.Fatalf("oracle client output:\n%s", out)
	}
}

func TestOracleGoClientCallsOfficialServer(t *testing.T) {
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

	client := echo.NewEchoClient(grpcdc.NewChannel(echo.NewStdioTransport(bridgeIn, bridgeOut)))
	runOracleScenarios(t, client) // generated driver (oracle-gen.rkt)
}

func TestOracleOfficialClientCallsGoServer(t *testing.T) {
	serverBin := filepath.Join(t.TempDir(), "echo_server_stdio")
	build := exec.Command("go", "build", "-o", serverBin, "./examples/echo_server_stdio")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build go server: %v\n%s", err, out)
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
