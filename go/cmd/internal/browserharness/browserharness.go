// Shared signaling and serving boilerplate for the browser-test
// Go harnesses (grpc_webrtc_server, grpc_webrtc_client,
// grpc_webrtc_eventbus_server). Hand-written test infrastructure
// (not generated): SDP offer/answer exchange through files, where
// <base>.offer and <base>.answer sit beside a caller-chosen base
// path, plus the answerer-side gRPC-over-DataChannel serve loop.
package browserharness

import (
	"fmt"
	"os"
	"strings"
	"time"

	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
)

// WaitForFile polls until path exists with non-blank content and
// returns the text.
func WaitForFile(path string) string {
	for {
		if content, err := os.ReadFile(path); err == nil {
			if text := string(content); strings.TrimSpace(text) != "" {
				return text
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// BaseArg returns os.Args[1] or exits with a usage line naming the
// binary.
func BaseArg(usage string) string {
	if len(os.Args) < 2 || os.Args[1] == "" {
		fmt.Fprintln(os.Stderr, "usage:", usage)
		os.Exit(2)
	}
	return os.Args[1]
}

// ServeAnswers answers the browser's offer from <base>.offer,
// writes the answer to <base>.answer, then serves the gRPC server
// built by register on every inbound DataChannel. Blocks forever.
func ServeAnswers(base string, register func(*grpcdc.Server)) {
	peer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{RequirePeerCertificate: false})
	if err != nil {
		panic(err)
	}
	offer := WaitForFile(base + ".offer")
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
	register(server)
	endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
		server.ServeTransport(grpcdc.NewDcTransport(channel))
	})
	select {}
}
