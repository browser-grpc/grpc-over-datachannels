// Event-bus browser-test harness: the native Go WebRTC stack
// answering a browser page, serving the generated EventBusBroker
// on every inbound DataChannel. Offer/answer are exchanged
// through files, mirroring grpc_webrtc_server.
//
// Usage: grpc_webrtc_eventbus_server <signaling-base-path>
package main

import (
	"fmt"
	"os"
	"time"

	dcwebrtc "dcwebrtc"
	grpcdc "grpcdc"
	busv1 "grpcdc/eventbus"
)

func waitForFile(path string) string {
	for {
		if content, err := os.ReadFile(path); err == nil && len(content) > 0 {
			return string(content)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func main() {
	if len(os.Args) < 2 || os.Args[1] == "" {
		fmt.Fprintln(os.Stderr, "usage: grpc_webrtc_eventbus_server <signaling-base-path>")
		os.Exit(2)
	}
	base := os.Args[1]
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
	broker := busv1.NewEventBusBroker()
	server := grpcdc.NewServer()
	broker.Register(server)
	endpoint.SetOnChannel(func(channel *dcwebrtc.DataChannel) {
		server.ServeTransport(grpcdc.NewDcTransport(channel))
	})
	select {}
}
