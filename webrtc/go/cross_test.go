package dcwebrtc

// Cross-implementation tests: Go stack against the JS stack
// (node harnesses) and the Rust stack (cargo examples). Each test
// skips when its external harness is unavailable, so `go test` on a
// bare Go toolchain stays green; Dockerfile.ci provides all of them.

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func repoPath(t *testing.T, rel string) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", "..", rel))
	if err != nil {
		t.Fatal(err)
	}
	return abs
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

// runEchoClient drives an echo-client harness: writes line, expects reply.
func runEchoClient(t *testing.T, cmd *exec.Cmd, line string) string {
	t.Helper()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Skipf("harness unavailable: %v", err)
	}
	defer cmd.Process.Kill()
	go func() {
		fmt.Fprintln(stdin, line)
	}()
	reader := bufio.NewReader(stdout)
	type readResult struct {
		line string
		err  error
	}
	resultCh := make(chan readResult, 1)
	go func() {
		text, err := reader.ReadString('\n')
		resultCh <- readResult{strings.TrimRight(text, "\n"), err}
	}()
	select {
	case result := <-resultCh:
		if result.err != nil && result.line == "" {
			t.Fatalf("client harness: %v", result.err)
		}
		return result.line
	case <-time.After(60 * time.Second):
		t.Fatal("echo client timed out")
		return ""
	}
}

func buildGoHarness(t *testing.T, name string) string {
	t.Helper()
	out := filepath.Join(t.TempDir(), name)
	cmd := exec.Command("go", "build", "-o", out, "./cmd/"+name)
	cmd.Dir = "."
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("go build %s: %v (%s)", name, err, output)
	}
	return out
}

func TestCrossJsDcEchoGoClient(t *testing.T) {
	harness := repoPath(t, "webrtc/js/examples/dc_echo.mjs")
	if _, err := os.Stat(harness); err != nil {
		t.Skip("JS harness missing")
	}
	port := freePort(t)
	server := exec.Command("node", harness, "server", fmt.Sprint(port))
	server.Stderr = os.Stderr
	if err := server.Start(); err != nil {
		t.Skipf("node unavailable: %v", err)
	}
	defer server.Process.Kill()
	time.Sleep(500 * time.Millisecond)
	clientBin := buildGoHarness(t, "dc_echo")
	reply := runEchoClient(t, exec.Command(clientBin, "client", fmt.Sprint(port)), "go to js")
	if reply != "re:go to js" {
		t.Fatalf("reply = %q", reply)
	}
}

func TestCrossJsDcEchoGoServer(t *testing.T) {
	harness := repoPath(t, "webrtc/js/examples/dc_echo.mjs")
	if _, err := os.Stat(harness); err != nil {
		t.Skip("JS harness missing")
	}
	port := freePort(t)
	serverBin := buildGoHarness(t, "dc_echo")
	server := exec.Command(serverBin, "server", fmt.Sprint(port))
	server.Stderr = os.Stderr
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	defer server.Process.Kill()
	time.Sleep(500 * time.Millisecond)
	reply := runEchoClient(t, exec.Command("node", harness, "client", fmt.Sprint(port)), "js to go")
	if reply != "re:js to go" {
		t.Fatalf("reply = %q", reply)
	}
}

func peerFiles(t *testing.T) (string, string) {
	dir := t.TempDir()
	return filepath.Join(dir, "offer.sdp"), filepath.Join(dir, "answer.sdp")
}

func TestCrossJsPeerGoOfferer(t *testing.T) {
	jsHarness := repoPath(t, "webrtc/js/examples/peer_echo.mjs")
	if _, err := os.Stat(jsHarness); err != nil {
		t.Skip("JS peer harness missing")
	}
	offer, answer := peerFiles(t)
	answerer := exec.Command("node", jsHarness, "answerer", offer, answer)
	answerer.Stderr = os.Stderr
	if err := answerer.Start(); err != nil {
		t.Skipf("node unavailable: %v", err)
	}
	defer answerer.Process.Kill()
	goBin := buildGoHarness(t, "peer_echo")
	reply := runEchoClient(t, exec.Command(goBin, "offerer", offer, answer), "go peer to js peer")
	if reply != "re:go peer to js peer" {
		t.Fatalf("reply = %q", reply)
	}
}

func TestCrossJsPeerGoAnswerer(t *testing.T) {
	jsHarness := repoPath(t, "webrtc/js/examples/peer_echo.mjs")
	if _, err := os.Stat(jsHarness); err != nil {
		t.Skip("JS peer harness missing")
	}
	offer, answer := peerFiles(t)
	goBin := buildGoHarness(t, "peer_echo")
	answerer := exec.Command(goBin, "answerer", offer, answer)
	answerer.Stderr = os.Stderr
	if err := answerer.Start(); err != nil {
		t.Fatal(err)
	}
	defer answerer.Process.Kill()
	reply := runEchoClient(t, exec.Command("node", jsHarness, "offerer", offer, answer), "js peer to go peer")
	if reply != "re:js peer to go peer" {
		t.Fatalf("reply = %q", reply)
	}
}

func TestCrossRustPeerGoOfferer(t *testing.T) {
	rustHarness := repoPath(t, "webrtc/rust/target/debug/examples/peer_echo")
	if _, err := os.Stat(rustHarness); err != nil {
		t.Skip("Rust peer_echo not built")
	}
	offer, answer := peerFiles(t)
	answerer := exec.Command(rustHarness, "answerer", offer, answer)
	answerer.Stderr = os.Stderr
	if err := answerer.Start(); err != nil {
		t.Fatal(err)
	}
	defer answerer.Process.Kill()
	goBin := buildGoHarness(t, "peer_echo")
	reply := runEchoClient(t, exec.Command(goBin, "offerer", offer, answer), "go peer to rust peer")
	if reply != "re:go peer to rust peer" {
		t.Fatalf("reply = %q", reply)
	}
}

var _ = io.EOF
