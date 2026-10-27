// Interop harness: the Go echo client over stdio. Prints one line per
// call shape to stderr (stdout carries frames) and exits non-zero on
// any failure.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
	echo "github.com/browser-grpc/grpc-over-datachannels/go/examples"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	transport := echo.NewStdioTransport(os.Stdout, os.Stdin)
	channel := grpcdc.NewChannel(transport)
	client := echo.NewEchoClient(channel)
	ctx := context.Background()
	req := func(message string, count int32) *echo.EchoRequest {
		return &echo.EchoRequest{Message: message, Count: count}
	}

	unary, err := client.Unary(ctx, req("hello", 0))
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "unary=%s\n", unary.Message)

	stream, err := client.ServerStream(ctx, req("tick", 3))
	if err != nil {
		return err
	}
	var ticks []string
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		ticks = append(ticks, fmt.Sprintf("%s#%d", resp.Message, resp.Index))
	}
	fmt.Fprintf(os.Stderr, "server_stream=%s\n", strings.Join(ticks, ","))

	joined, err := client.ClientStream(ctx, req("a", 0), req("b", 0), req("c", 0))
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "client_stream=%s\n", joined.Message)

	bidi, err := client.Bidi(ctx, req("x", 0), req("y", 0))
	if err != nil {
		return err
	}
	var echoed []string
	for {
		resp, err := bidi.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		echoed = append(echoed, resp.Message)
	}
	fmt.Fprintf(os.Stderr, "bidi=%s\n", strings.Join(echoed, ","))

	_, err = client.Unary(ctx, req("fail", 0))
	if err == nil {
		fmt.Fprintln(os.Stderr, "error_case=no error")
	} else {
		fmt.Fprintf(os.Stderr, "error_case=%s\n", err)
	}

	mdResp := &echo.EchoResponse{}
	err = channel.UnaryWithMetadata(ctx, "/echo.Echo/Unary", req("hello", 0), mdResp,
		map[string]string{"x-echo": "meta"})
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "metadata=%s\n", mdResp.Message)

	slow := req("slow", 0)
	slow.DelayMs = 400
	dctx, dcancel := context.WithTimeout(ctx, 50_000_000)
	defer dcancel()
	_, err = client.Unary(dctx, slow)
	var status *grpcdc.StatusError
	if err == nil {
		fmt.Fprintln(os.Stderr, "deadline=no error")
	} else if errors.As(err, &status) {
		fmt.Fprintf(os.Stderr, "deadline=%d\n", int(status.Code))
	} else {
		fmt.Fprintf(os.Stderr, "deadline=err:%s\n", err)
	}
	return nil
}
