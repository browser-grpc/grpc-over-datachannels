// gRPC-over-WebRTC server harness for browser tests:
//
//	grpc_webrtc_server <ready-file>
//
// Writes its answer SDP to <ready-file>.answer after reading the
// browser's offer from <ready-file>.offer; runs the generated Echo
// service on every inbound DataChannel. Used by
// browser-test/go_server.test.mjs (Playwright).
package main

import (
	"fmt"
	"os"
	"time"

	dcwebrtc "dcwebrtc"
	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func waitForFile(path string) string {
	for {
		if content, err := os.ReadFile(path); err == nil {
			text := string(content)
			nonBlank := false
			for _, r := range text {
				if r != ' ' && r != '\n' && r != '\r' && r != '\t' {
					nonBlank = true
				}
			}
			if nonBlank {
				return text
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func main() {
	base := ""
	if len(os.Args) > 1 {
		base = os.Args[1]
	}
	if base == "" {
		fmt.Fprintln(os.Stderr, "usage: grpc_webrtc_server <signaling-base-path>")
		os.Exit(2)
	}
	peer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{RequirePeerCertificate: false})
	if err != nil {
		panic(err)
	}
	offer := waitForFile(base + ".offer")
	answer, err := peer.HandleOffer(offer)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(base+".answer", []byte(answer), 0o644); err != nil {
		panic(err)
	}
	fmt.Fprintln(os.Stderr, "ANSWER_WRITTEN")
	endpoint, err := peer.ConnectWithOptions(false)
	if err != nil {
		panic(err)
	}
	fmt.Fprintln(os.Stderr, "CONNECTED")
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
		server.ServeTransport(grpcdc.NewDcTransport(channel))
	})
	select {}
}
