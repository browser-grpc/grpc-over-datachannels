// gRPC-over-WebRTC server harness for browser tests:
//
//	grpc_webrtc_server <signaling-base-path>
//
// Writes its answer SDP to <base>.answer after reading the
// browser's offer from <base>.offer; runs the generated Echo
// service on every inbound DataChannel. Used by
// browser-test/go_server.test.mjs (Playwright).
package main

import (
	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	bh "github.com/browser-grpc/grpc-over-datachannels/go/cmd/internal/browserharness"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func main() {
	base := bh.BaseArg("grpc_webrtc_server <signaling-base-path>")
	bh.ServeAnswers(base, func(server *grpcdc.Server) {
		echo.RegisterEchoServer(server, echo.EchoService{})
	})
}
