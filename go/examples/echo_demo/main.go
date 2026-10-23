// Echo demo: all four gRPC method shapes over one in-memory transport.
// `go run ./examples/echo_demo` from the go/ directory.
package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	grpcdc "grpcdc"
	echo "grpcdc/examples"
)

func main() {
	a, b := grpcdc.MemoryTransportPair()
	server := grpcdc.NewServer()
	echo.RegisterEchoServer(server, echo.EchoService{})
	server.ServeTransport(b)

	client := echo.NewEchoClient(grpcdc.NewChannel(a))
	ctx := context.Background()
	req := func(message string, count int32) *echo.EchoRequest {
		return &echo.EchoRequest{Message: message, Count: count}
	}

	unary, err := client.Unary(ctx, req("hello", 0))
	must(err)
	fmt.Printf("unary        -> %s (index %d)\n", unary.Message, unary.Index)

	stream, err := client.ServerStream(ctx, req("tick", 3))
	must(err)
	var ticks []string
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		must(err)
		ticks = append(ticks, fmt.Sprintf("%s#%d", resp.Message, resp.Index))
	}
	fmt.Printf("server-stream-> %s\n", strings.Join(ticks, ", "))

	joined, err := client.ClientStream(ctx, req("a", 0), req("b", 0), req("c", 0))
	must(err)
	fmt.Printf("client-stream-> %s (%d parts)\n", joined.Message, joined.Index)

	bidi, err := client.Bidi(ctx, req("x", 0), req("y", 0))
	must(err)
	var echoed []string
	for {
		resp, err := bidi.Recv()
		if err == io.EOF {
			break
		}
		must(err)
		echoed = append(echoed, resp.Message)
	}
	fmt.Printf("bidi         -> %s\n", strings.Join(echoed, ", "))
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
