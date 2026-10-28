package echo

// Dynamic Echo implementation: the reference Echo semantics built
// purely on the descriptor-driven runtime (no generated stubs).
// Field numbers come from proto/echo.proto: EchoRequest{message=1,
// count=2}, EchoResponse{message=1, index=2}.

import (
	"context"
	"io"

	grpcdc "github.com/browser-grpc/grpc-over-datachannels/go"
)

func dynamicResponse(method *grpcdc.MethodModel, message string, index int64) *grpcdc.GenericMessage {
	return grpcdc.NewGenericMessage(method.Output).Set(1, message).Set(2, index)
}

// DynamicEchoService implements grpcdc.DynamicHandler.
type DynamicEchoService struct{}

// Unary implements grpcdc.DynamicHandler.
func (DynamicEchoService) Unary(ctx context.Context, method *grpcdc.MethodModel, req *grpcdc.GenericMessage) (*grpcdc.GenericMessage, error) {
	message := req.GetString(1)
	if message == "fail" {
		return nil, grpcdc.NewStatus(grpcdc.CodeInvalidArgument, "asked to fail")
	}
	suffix := ""
	if md := grpcdc.MetadataFromContext(ctx); md["x-echo"] != "" {
		suffix = " [" + md["x-echo"] + "]"
	}
	return dynamicResponse(method, "echo: "+message+suffix, 0), nil
}

// ServerStream implements grpcdc.DynamicHandler.
func (DynamicEchoService) ServerStream(ctx context.Context, method *grpcdc.MethodModel, req *grpcdc.GenericMessage, send func(*grpcdc.GenericMessage) error) error {
	for i := int64(0); i < req.GetInt(2); i++ {
		if err := send(dynamicResponse(method, req.GetString(1), i)); err != nil {
			return err
		}
	}
	return nil
}

// ClientStream implements grpcdc.DynamicHandler.
func (DynamicEchoService) ClientStream(ctx context.Context, method *grpcdc.MethodModel, recv func() (*grpcdc.GenericMessage, error)) (*grpcdc.GenericMessage, error) {
	joined := ""
	count := int64(0)
	for {
		req, err := recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if count > 0 {
			joined += "+"
		}
		joined += req.GetString(1)
		count++
	}
	return dynamicResponse(method, joined, count), nil
}

// Bidi implements grpcdc.DynamicHandler.
func (DynamicEchoService) Bidi(ctx context.Context, method *grpcdc.MethodModel, recv func() (*grpcdc.GenericMessage, error), send func(*grpcdc.GenericMessage) error) error {
	var index int64
	for {
		req, err := recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := send(dynamicResponse(method, req.GetString(1), index)); err != nil {
			return err
		}
		index++
	}
}
