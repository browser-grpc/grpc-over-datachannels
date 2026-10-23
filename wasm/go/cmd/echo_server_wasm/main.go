//go:build js && wasm

// Browser server entry for the Go/WASM facade test: registers
// the generated EchoServer implementation with the page's JS
// server bridge (window.__grpcDcServerBridge, installed by
// wasm_go_facade_server_page.html from createGrpcDcServerBridge).
// The JS grpc-dc Server owns the wire; this Go impl owns only
// the typed handlers. Handlers run on goroutines spawned by the
// bridge helpers, so the delay may simply sleep.
package main

import (
	"strings"
	"syscall/js"
	"time"

	echowasm "wasmecho"
	echo "grpcdc/examples"
)

type slowEcho struct{}

func metadataGet(metadata [][2]string, key string) string {
	for _, pair := range metadata {
		if pair[0] == key {
			return pair[1]
		}
	}
	return ""
}

func copyResp(req *echo.EchoRequest, metadata [][2]string) *echo.EchoResponse {
	message := "echo: " + req.Message
	if marker := metadataGet(metadata, "x-echo"); marker != "" {
		message += " [" + marker + "]"
	}
	return &echo.EchoResponse{Message: message}
}

func maybeDelay(req *echo.EchoRequest) {
	if req.DelayMs > 0 {
		time.Sleep(time.Duration(req.DelayMs) * time.Millisecond)
	}
}

func (slowEcho) Unary(req *echo.EchoRequest, metadata [][2]string) (*echo.EchoResponse, error) {
	if req.Message == "fail" {
		return nil, &echowasm.StatusError{Code: 3, Message: "asked to fail"}
	}
	maybeDelay(req)
	return copyResp(req, metadata), nil
}

func (slowEcho) ServerStream(req *echo.EchoRequest, metadata [][2]string, sink *echowasm.EchoServerSink) error {
	if req.Message == "fail" {
		return &echowasm.StatusError{Code: 3, Message: "asked to fail"}
	}
	maybeDelay(req)
	for i := int32(0); i < req.Count; i++ {
		if err := sink.Send(&echo.EchoResponse{Message: req.Message, Index: i}); err != nil {
			return err
		}
	}
	return nil
}

func (slowEcho) ClientStream(reqs []*echo.EchoRequest, metadata [][2]string) (*echo.EchoResponse, error) {
	parts := make([]string, len(reqs))
	for i, req := range reqs {
		if req.Message == "fail" {
			return nil, &echowasm.StatusError{Code: 3, Message: "asked to fail"}
		}
		parts[i] = req.Message
	}
	return &echo.EchoResponse{Message: strings.Join(parts, "+")}, nil
}

func (slowEcho) Bidi(reqs []*echo.EchoRequest, metadata [][2]string, sink *echowasm.EchoServerSink) error {
	for _, req := range reqs {
		if req.Message == "fail" {
			return &echowasm.StatusError{Code: 3, Message: "asked to fail"}
		}
	}
	for _, req := range reqs {
		if err := sink.Send(&echo.EchoResponse{Message: req.Message}); err != nil {
			return err
		}
	}
	return nil
}

func main() {
	bridge := js.Global().Get("__grpcDcServerBridge")
	echowasm.RegisterEchoServer(bridge, slowEcho{})
	select {} // keep the wasm runtime alive for callbacks
}
