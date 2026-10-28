package grpcdc_test

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
	"testing"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

// BDD scenarios over the WebRTC-Direct sidecar transport: same
// generated scenario table as TestBdd, but the Go client+server
// run over the real WebRTC stack owned by two direct_sidecar
// processes (Rust) -- one listens, one dials by multiaddr; Go
// only speaks length-prefixed TCP to its local sidecar.

func TestBddSidecar(t *testing.T) {
	bin := sidecarBinary(t)

	// Go server behind sidecar `listen`.
	langPort := sidecarFreePort(t)
	serverSock, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", langPort))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = serverSock.Close() }()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	go func() {
		conn, err := serverSock.Accept()
		if err == nil {
			_ = server.ServeTransport(grpcdc.NewSidecarTransport(conn))
		}
	}()

	listenCmd := exec.Command(bin, "listen", "--udp", "127.0.0.1:0", "--tcp", fmt.Sprintf("127.0.0.1:%d", langPort))
	defer func() {
		if listenCmd.Process != nil {
			_ = listenCmd.Process.Kill()
		}
	}()
	multiaddr := strings.SplitN(readSidecarLine(t, listenCmd, "MULTIADDR"), " ", 2)[1]

	// Go client behind sidecar `dial`.
	clientPort := sidecarFreePort(t)
	dialCmd := exec.Command(bin, "dial", "--multiaddr", multiaddr, "--tcp", fmt.Sprintf("127.0.0.1:%d", clientPort))
	defer func() {
		if dialCmd.Process != nil {
			_ = dialCmd.Process.Kill()
		}
	}()
	_ = readSidecarLine(t, dialCmd, "TCP")

	transport, err := grpcdc.DialSidecar(fmt.Sprintf("127.0.0.1:%d", clientPort))
	if err != nil {
		t.Fatal(err)
	}
	channel := grpcdc.NewChannel(transport)
	client := echo.NewEchoClient(channel)
	runBddScenarios(t, channel, client)
}
