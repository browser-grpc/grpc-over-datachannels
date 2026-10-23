<?php
// Dynamic Echo implementation: the reference Echo semantics built
// purely on the descriptor-driven runtime (no generated stubs).
// Field numbers come from proto/echo.proto: EchoRequest{message=1,
// count=2}, EchoResponse{message=1, index=2}.

require_once __DIR__ . "/../grpcdc.php";

// Handler protocol for Grpcdc\Dyn::registerDynamicService.
class DynamicEchoService
{
    public function unary(\Grpcdc\CallContext $ctx, \Grpcdc\MethodModel $method, \Grpcdc\GenericMessage $request): \Grpcdc\GenericMessage
    {
        $message = $request->getString(1);
        if ($message === "fail") {
            throw new \Grpcdc\StatusError(\Grpcdc\Wire::CODE_INVALID_ARGUMENT, "asked to fail");
        }
        $suffix = "";
        if (isset($ctx->metadata["x-echo"])) {
            $suffix = " [" . $ctx->metadata["x-echo"] . "]";
        }
        return $this->response($method, "echo: " . $message . $suffix, 0);
    }

    public function serverStream(\Grpcdc\CallContext $ctx, \Grpcdc\MethodModel $method, \Grpcdc\GenericMessage $request, \Closure $send): void
    {
        for ($i = 0; $i < max(0, $request->getInt(2)); $i++) {
            $send($this->response($method, $request->getString(1), $i));
        }
    }

    public function clientStream(\Grpcdc\CallContext $ctx, \Grpcdc\MethodModel $method, \Generator $requests): \Grpcdc\GenericMessage
    {
        $parts = [];
        foreach ($requests as $req) {
            $parts[] = $req->getString(1);
        }
        return $this->response($method, implode("+", $parts), count($parts));
    }

    public function bidi(\Grpcdc\CallContext $ctx, \Grpcdc\MethodModel $method, \Generator $requests, \Closure $send): void
    {
        $index = 0;
        foreach ($requests as $req) {
            $send($this->response($method, $req->getString(1), $index));
            $index++;
        }
    }

    private function response(\Grpcdc\MethodModel $method, string $message, int $index): \Grpcdc\GenericMessage
    {
        return (new \Grpcdc\GenericMessage($method->output))->set(1, $message)->set(2, $index);
    }
}
