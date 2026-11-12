// Rendezvous Echo server harness for browser tests: serves
// the generated Echo service on a fixed rendezvous endpoint
// (grpcdc.ServeRendezvous) and prints the publishable
// descriptor as one JSON line on stdout. Browsers dial it
// with rendezvousChannel — no signaling. Used by
// browser-test/rendezvous_stacks.test.mjs (Playwright).
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
)

// outwardIP is this host's default-route IPv4, as a real
// deployment would publish its public address.
func outwardIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:53")
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok && addr.IP != nil {
		return addr.IP.String()
	}
	return "127.0.0.1"
}

func main() {
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	listener, err := grpcdc.ServeRendezvous(server,
		&net.UDPAddr{IP: net.IPv4zero, Port: 0},
		dcwebrtc.RendezvousOptions{OnError: func(err error) {
			fmt.Fprintln(os.Stderr, "rendezvous:", err)
		}})
	if err != nil {
		fmt.Fprintln(os.Stderr, "rendezvous_server:", err)
		os.Exit(1)
	}
	defer listener.Close()
	line, err := json.Marshal(listener.Descriptor(outwardIP()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "rendezvous_server:", err)
		os.Exit(1)
	}
	fmt.Println(string(line))
	select {}
}
