// gRPC-over-WebRTC client harness for browser tests:
//
//	grpc_webrtc_client <signaling-base-path> [dtls-server]
//
// Writes its offer SDP to <base>.offer, reads the browser's answer
// from <base>.answer, then runs the generated Echo client over the
// "grpc" DataChannel — the browser is the server in this harness.
// Results go to stderr; exit code is non-zero on any mismatch.
// Used by browser-test/browser_server.test.mjs (Playwright, default
// mode: this side is the DTLS client) and
// browser-test/dtls_server.test.mjs ("dtls-server" mode: the offer
// keeps setup=actpass, the browser answers setup=active, and this
// side accepts as the DTLS server).
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	dcwebrtc "github.com/browser-grpc/grpc-over-datachannels/webrtc/go"
	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	bh "github.com/browser-grpc/grpc-over-datachannels/go/cmd/internal/browserharness"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

func main() {
	base := ""
	if len(os.Args) > 1 {
		base = os.Args[1]
	}
	dtlsServer := len(os.Args) > 2 && os.Args[2] == "dtls-server"
	if base == "" {
		fmt.Fprintln(os.Stderr, "usage: grpc_webrtc_client <signaling-base-path>")
		os.Exit(2)
	}
	peer, err := dcwebrtc.NewPeer(dcwebrtc.PeerOptions{RequirePeerCertificate: false})
	if err != nil {
		panic(err)
	}
	offer := peer.CreateOffer()
	if !dtlsServer {
		// Ask for the DTLS client role (setup:active instead of
		// actpass): the browser then acts as DTLS server.
		// HandleAnswer derives our role from the answer's
		// setup:passive, keeping both sides consistent. In
		// dtls-server mode the actpass offer stands and the
		// browser answers setup=active, making this side the DTLS
		// server instead.
		offer = strings.Replace(offer, "a=setup:actpass", "a=setup:active", 1)
	}
	if err := os.WriteFile(base+".offer", []byte(offer), 0o644); err != nil {
		panic(err)
	}
	fmt.Fprintln(os.Stderr, "OFFER_WRITTEN")
	answer := bh.WaitForFile(base + ".answer")
	if err := peer.HandleAnswer(answer); err != nil {
		panic(err)
	}
	endpoint, err := peer.ConnectWithOptions(true)
	if err != nil {
		panic(err)
	}
	fmt.Fprintln(os.Stderr, "CONNECTED")

	channel := endpoint.OpenChannel(dcwebrtc.DefaultChannelParams("grpc"))
	grpcChannel := grpcdc.NewChannel(grpcdc.NewDcTransport(channel))
	client := echo.NewEchoClient(grpcChannel)
	ctx := context.Background()

	unary, err := client.Unary(ctx, &echo.EchoRequest{Message: "hello"})
	if err != nil {
		fatal(err)
	}
	fmt.Fprintf(os.Stderr, "unary=%s\n", unary.Message)

	stream, err := client.ServerStream(ctx, &echo.EchoRequest{Message: "tick", Count: 3})
	if err != nil {
		fatal(err)
	}
	var ticks []string
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			fatal(err)
		}
		ticks = append(ticks, fmt.Sprintf("%s#%d", resp.Message, resp.Index))
	}
	fmt.Fprintf(os.Stderr, "server_stream=%s\n", strings.Join(ticks, ","))

	joined, err := client.ClientStream(ctx,
		&echo.EchoRequest{Message: "a"}, &echo.EchoRequest{Message: "b"}, &echo.EchoRequest{Message: "c"})
	if err != nil {
		fatal(err)
	}
	fmt.Fprintf(os.Stderr, "client_stream=%s\n", joined.Message)

	bidi, err := client.Bidi(ctx, &echo.EchoRequest{Message: "x"}, &echo.EchoRequest{Message: "y"})
	if err != nil {
		fatal(err)
	}
	var echoed []string
	for {
		resp, err := bidi.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			fatal(err)
		}
		echoed = append(echoed, resp.Message)
	}
	fmt.Fprintf(os.Stderr, "bidi=%s\n", strings.Join(echoed, ","))

	_, err = client.Unary(ctx, &echo.EchoRequest{Message: "fail"})
	if err == nil {
		fmt.Fprintln(os.Stderr, "error_case=no error")
	} else {
		fmt.Fprintf(os.Stderr, "error_case=%s\n", err)
	}

	mdResp := &echo.EchoResponse{}
	err = grpcChannel.UnaryWithMetadata(ctx, "/echo.Echo/Unary", &echo.EchoRequest{Message: "hello"}, mdResp,
		map[string]string{"x-echo": "meta"})
	if err != nil {
		fatal(err)
	}
	fmt.Fprintf(os.Stderr, "metadata=%s\n", mdResp.Message)

	dctx, dcancel := context.WithTimeout(ctx, 50*time.Millisecond)
	_, err = client.Unary(dctx, &echo.EchoRequest{Message: "slow", DelayMs: 400})
	dcancel()
	var status *grpcdc.StatusError
	if err == nil {
		fmt.Fprintln(os.Stderr, "deadline=no error")
	} else if errors.As(err, &status) {
		fmt.Fprintf(os.Stderr, "deadline=%d\n", int(status.Code))
	} else {
		fmt.Fprintf(os.Stderr, "deadline=err:%s\n", err)
	}
	fmt.Fprintln(os.Stderr, "CLIENT_DONE")
}
