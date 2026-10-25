<?php
// Reference Echo implementation (mirrors the Rust/JS/Go demos):
// "fail" is rejected, everything else echoes.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/echo_pb.php";

class EchoService
{
    public function Unary(\Grpcdc\CallContext $ctx, \EchoPb\EchoRequest $req): \EchoPb\EchoResponse
    {
        if ($req->message === "fail") {
            throw new \Grpcdc\StatusError(\Grpcdc\Wire::CODE_INVALID_ARGUMENT, "asked to fail");
        }
        if ($req->delayMs > 0) {
            usleep($req->delayMs * 1000);
        }
        $suffix = "";
        if (isset($ctx->metadata["x-echo"])) {
            $suffix = " [" . $ctx->metadata["x-echo"] . "]";
        }
        if (isset($ctx->metadata["x-echo-trailer"])) {
            $ctx->setTrailers(["x-echo-trailer" => $ctx->metadata["x-echo-trailer"]]);
        }
        return new \EchoPb\EchoResponse("echo: " . $req->message . $suffix, 0);
    }

    public function ServerStream(\EchoPb\EchoRequest $req, \EchoGrpcDc\SendStream $stream): void
    {
        if ($req->message === "fail") {
            throw new \Grpcdc\StatusError(\Grpcdc\Wire::CODE_INVALID_ARGUMENT, "asked to fail");
        }
        for ($i = 0; $i < max(0, $req->count); $i++) {
            $stream->send(new \EchoPb\EchoResponse($req->message, $i));
        }
    }

    public function ClientStream(\EchoGrpcDc\ClientStreamImpl $stream): void
    {
        $parts = [];
        try {
            while (true) {
                $req = $stream->recv();
                $parts[] = $req->message;
            }
        } catch (\Grpcdc\CallClosed $e) {
        }
        $stream->sendAndClose(new \EchoPb\EchoResponse(implode("+", $parts), count($parts)));
    }

    public function Bidi(\EchoGrpcDc\BidiStream $stream): void
    {
        $index = 0;
        try {
            while (true) {
                $req = $stream->recv();
                if ($req->message === "fail") {
                    throw new \Grpcdc\StatusError(\Grpcdc\Wire::CODE_INVALID_ARGUMENT, "asked to fail");
                }
                $stream->send(new \EchoPb\EchoResponse($req->message, $index));
                $index++;
            }
        } catch (\Grpcdc\CallClosed $e) {
        }
    }
}
