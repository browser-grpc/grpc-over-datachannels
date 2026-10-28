//go:build js && wasm

// Incremental browser server entry for the Go/WASM facade
// test: registers the generated EchoStreamServer, whose
// handlers pull requests one at a time (Next) instead of
// receiving them collected. The page's ping-pong bidi call
// proves a response lands before the next request is sent.
package main

import (
	"strings"
	"syscall/js"

	echowasm "wasmecho"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

type slowEchoStream struct{}

func (slowEchoStream) ClientStream(source *echowasm.EchoRequestSource, metadata [][2]string) (*echo.EchoResponse, error) {
	var parts []string
	for {
		req, err := source.Next()
		if err != nil {
			return nil, err
		}
		if req == nil {
			break
		}
		if req.Message == "fail" {
			return nil, &echowasm.StatusError{Code: 3, Message: "asked to fail"}
		}
		parts = append(parts, req.Message)
	}
	return &echo.EchoResponse{Message: strings.Join(parts, "+"), Index: int32(len(parts))}, nil
}

func (slowEchoStream) Bidi(source *echowasm.EchoRequestSource, metadata [][2]string, sink *echowasm.EchoServerSink) error {
	var index int32
	for {
		req, err := source.Next()
		if err != nil {
			return err
		}
		if req == nil {
			return nil
		}
		if req.Message == "fail" {
			return &echowasm.StatusError{Code: 3, Message: "asked to fail"}
		}
		if err := sink.Send(&echo.EchoResponse{Message: req.Message, Index: index}); err != nil {
			return err
		}
		index++
	}
}

func main() {
	bridge := js.Global().Get("__grpcDcServerBridge")
	echowasm.RegisterEchoStreamServer(bridge, slowEchoStream{})
	bridge.Call("start", "echo.Echo")
	select {} // keep the wasm runtime alive for callbacks
}
