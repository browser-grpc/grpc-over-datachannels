// Interop harness: the Go echo client over stdio. Prints one line per
// call shape to stderr (stdout carries frames) and exits non-zero on
// any failure.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	transport := echo.NewStdioTransport(os.Stdout, os.Stdin)
	client := echo.NewEchoClient(grpcdc.NewChannel(transport))
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
	return nil
}
