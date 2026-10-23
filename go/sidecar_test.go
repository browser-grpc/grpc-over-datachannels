package grpcdc_test

// gRPC over WebRTC-Direct via the Rust sidecar, Go to Go: two
// direct_sidecar processes own the WebRTC stack; the Go server
// and client only speak length-prefixed TCP to their local
// sidecar (grpcdc.SidecarTransport / DialSidecar).

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func sidecarBinary(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..")
	bin := filepath.Join(root, "webrtc", "rust", "target", "debug", "examples", "direct_sidecar")
	if _, err := os.Stat(bin); err != nil {
		cmd := exec.Command("cargo", "build", "--example", "direct_sidecar")
		cmd.Dir = filepath.Join(root, "webrtc", "rust")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("build sidecar: %v\n%s", err, out)
		}
	}
	abs, _ := filepath.Abs(bin)
	return abs
}

func sidecarFreePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func readSidecarLine(t *testing.T, cmd *exec.Cmd, needle string) string {
	t.Helper()
	out, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(out)
	deadline := time.Now().Add(30 * time.Second)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, needle) {
			return strings.TrimSpace(line)
		}
		if time.Now().After(deadline) {
			break
		}
	}
	t.Fatalf("sidecar did not print %q", needle)
	return ""
}

func TestSidecarDirectGo(t *testing.T) {
	bin := sidecarBinary(t)

	// Go server behind sidecar `listen`.
	langPort := sidecarFreePort(t)
	serverSock, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", langPort))
	if err != nil {
		t.Fatal(err)
	}
	defer serverSock.Close()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	go func() {
		conn, err := serverSock.Accept()
		if err == nil {
			server.ServeTransport(grpcdc.NewSidecarTransport(conn))
		}
	}()

	listenCmd := exec.Command(bin, "listen", "--udp", "127.0.0.1:0", "--tcp", fmt.Sprintf("127.0.0.1:%d", langPort))
	defer func() { if listenCmd.Process != nil { _ = listenCmd.Process.Kill() } }()
	multiaddr := strings.SplitN(readSidecarLine(t, listenCmd, "MULTIADDR"), " ", 2)[1]
	if !strings.Contains(multiaddr, "/webrtc-direct/certhash/f") {
		t.Fatalf("multiaddr = %s", multiaddr)
	}

	// Go client behind sidecar `dial`.
	clientPort := sidecarFreePort(t)
	dialCmd := exec.Command(bin, "dial", "--multiaddr", multiaddr, "--tcp", fmt.Sprintf("127.0.0.1:%d", clientPort))
	defer func() { if dialCmd.Process != nil { _ = dialCmd.Process.Kill() } }()
	_ = readSidecarLine(t, dialCmd, "TCP")

	transport, err := grpcdc.DialSidecar(fmt.Sprintf("127.0.0.1:%d", clientPort))
	if err != nil {
		t.Fatal(err)
	}
	client := echo.NewEchoClient(grpcdc.NewChannel(transport))
	resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: "hello"})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Message != "echo: hello" {
		t.Fatalf("unary = %q", resp.Message)
	}
}

// Three Go clients concurrently through ONE listen sidecar and
// ONE dial sidecar: the sidecars bridge per connection (one
// thread each), the Go server accepts a loop of framed TCP
// connections, and every client's payload must come back its
// own. Needs the sidecar's per-connection threading.
func TestSidecarMultiConnGo(t *testing.T) {
	bin := sidecarBinary(t)

	langPort := sidecarFreePort(t)
	serverSock, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", langPort))
	if err != nil {
		t.Fatal(err)
	}
	defer serverSock.Close()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	go func() {
		for {
			conn, err := serverSock.Accept()
			if err != nil {
				return
			}
			go server.ServeTransport(grpcdc.NewSidecarTransport(conn))
		}
	}()

	listenCmd := exec.Command(bin, "listen", "--udp", "127.0.0.1:0", "--tcp", fmt.Sprintf("127.0.0.1:%d", langPort))
	defer func() { if listenCmd.Process != nil { _ = listenCmd.Process.Kill() } }()
	multiaddr := strings.SplitN(readSidecarLine(t, listenCmd, "MULTIADDR"), " ", 2)[1]

	clientPort := sidecarFreePort(t)
	dialCmd := exec.Command(bin, "dial", "--multiaddr", multiaddr, "--tcp", fmt.Sprintf("127.0.0.1:%d", clientPort))
	defer func() { if dialCmd.Process != nil { _ = dialCmd.Process.Kill() } }()
	_ = readSidecarLine(t, dialCmd, "TCP")

	errs := make(chan error, 3)
	for i := 0; i < 3; i++ {
		go func(i int) {
			transport, err := grpcdc.DialSidecar(fmt.Sprintf("127.0.0.1:%d", clientPort))
			if err != nil {
				errs <- err
				return
			}
			client := echo.NewEchoClient(grpcdc.NewChannel(transport))
			want := fmt.Sprintf("echo: hello-%d", i)
			resp, err := client.Unary(context.Background(), &echo.EchoRequest{Message: fmt.Sprintf("hello-%d", i)})
			if err != nil {
				errs <- err
				return
			}
			if resp.Message != want {
				errs <- fmt.Errorf("client %d unary = %q, want %q", i, resp.Message, want)
				return
			}
			errs <- nil
		}(i)
	}
	for i := 0; i < 3; i++ {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
}
