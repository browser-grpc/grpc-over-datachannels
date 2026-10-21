package echo

import (
	"context"
	"io"
	"time"
	"strings"

	grpcdc "grpcdc"
)

// EchoService is the reference Echo implementation (mirrors the Rust
// and JS demos): "fail" is rejected, everything else echoes.
type EchoService struct{}

// Unary implements EchoServer.
func (EchoService) Unary(ctx context.Context, req *EchoRequest) (*EchoResponse, error) {
	if req.Message == "fail" {
		return nil, grpcdc.NewStatus(grpcdc.CodeInvalidArgument, "asked to fail")
	}
	if req.DelayMs > 0 {
		time.Sleep(time.Duration(req.DelayMs) * time.Millisecond)
	}
	suffix := ""
	if md := grpcdc.MetadataFromContext(ctx); md["x-echo"] != "" {
		suffix = " [" + md["x-echo"] + "]"
	}
	return &EchoResponse{Message: "echo: " + req.Message + suffix, Index: 0}, nil
}

// ServerStream implements EchoServer.
func (EchoService) ServerStream(req *EchoRequest, stream EchoServerStreamServer) error {
	if req.Message == "fail" {
		return grpcdc.NewStatus(grpcdc.CodeInvalidArgument, "asked to fail")
	}
	for i := int32(0); i < req.Count; i++ {
		if err := stream.Send(&EchoResponse{Message: req.Message, Index: i}); err != nil {
			return err
		}
	}
	return nil
}

// ClientStream implements EchoServer.
func (EchoService) ClientStream(stream EchoClientStreamServer) error {
	var parts []string
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		parts = append(parts, req.Message)
	}
	return stream.SendAndClose(&EchoResponse{
		Message: strings.Join(parts, "+"),
		Index:   int32(len(parts)),
	})
}

// Bidi implements EchoServer.
func (EchoService) Bidi(stream EchoBidiServer) error {
	var index int32
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if req.Message == "fail" {
			return grpcdc.NewStatus(grpcdc.CodeInvalidArgument, "asked to fail")
		}
		if err := stream.Send(&EchoResponse{Message: req.Message, Index: index}); err != nil {
			return err
		}
		index++
	}
}
