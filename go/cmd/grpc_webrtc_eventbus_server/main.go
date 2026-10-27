// Event-bus browser-test harness: the native Go WebRTC stack
// answering a browser page, serving the generated EventBusBroker
// on every inbound DataChannel. Offer/answer are exchanged
// through files, mirroring grpc_webrtc_server.
//
// Usage: grpc_webrtc_eventbus_server <signaling-base-path>
package main

import (
	bh "github.com/browser-grpc/grpc-over-datachannels/go/cmd/internal/browserharness"
	busv1 "github.com/browser-grpc/grpc-over-datachannels/go/eventbus"
)

func main() {
	base := bh.BaseArg("grpc_webrtc_eventbus_server <signaling-base-path>")
	broker := busv1.NewEventBusBroker()
	bh.ServeAnswers(base, broker.Register)
}
