<?php
// Hand-written TestService implementation for the interop
// oracle (Direction B: official grpc-java / grpc-go clients
// against this server, through the bridge). Mirrors
// js/test/interop_service.js.

require_once __DIR__ . "/../grpcdc.php";
require_once __DIR__ . "/messages_pb.php";
require_once __DIR__ . "/empty_pb.php";
require_once __DIR__ . "/orca_load_report_pb.php";

class InteropServiceImpl
{
    private const INITIAL_KEY = "x-grpc-test-echo-initial";
    private const TRAILING_KEY = "x-grpc-test-echo-trailing-bin";

    private static ?\OrcaLoadReportPb\OrcaLoadReport $oobReport = null;

    /** Wired by the stdio main to the endpoint pump so
     *  concurrent streams keep moving while StreamCoreMetrics
     *  loops (the generated endpoint supports reentrant
     *  dispatch from inside handlers). */
    public ?\Closure $pumpFn = null;

    private function echoMetadata(\Grpcdc\CallContext $ctx): void
    {
        $md = $ctx->metadata;
        if (isset($md[self::INITIAL_KEY])) {
            $ctx->setHeaders([self::INITIAL_KEY => $md[self::INITIAL_KEY]]);
        }
        if (isset($md[self::TRAILING_KEY])) {
            $ctx->setTrailers([self::TRAILING_KEY => $md[self::TRAILING_KEY]]);
        }
    }

    private function checkStatus(?\MessagesPb\EchoStatus $status): void
    {
        if ($status !== null && $status->code !== 0) {
            throw new \Grpcdc\StatusError($status->code, $status->message);
        }
    }

    /** @param object $stream SendStream|BidiStream (both ->send). */
    private function sendResponses(\MessagesPb\StreamingOutputCallRequest $req, object $stream): void
    {
        foreach ($req->responseParameters as $params) {
            if ($params->intervalUs > 0) {
                usleep($params->intervalUs);
                // Let a cancellation land between interval
                // sleeps instead of after the whole sequence.
                if ($this->pumpFn !== null) {
                    ($this->pumpFn)();
                }
            }
            $stream->send(new \MessagesPb\StreamingOutputCallResponse(
                new \MessagesPb\Payload($req->responseType, str_repeat("\0", $params->size))
            ));
        }
    }

    private function setOrcaTrailer(\Grpcdc\CallContext $ctx, \MessagesPb\TestOrcaReport $report): void
    {
        $loadReport = new \OrcaLoadReportPb\OrcaLoadReport(
            $report->cpuUtilization,
            $report->memoryUtilization,
            0.0,
            $report->requestCost,
            $report->utilization
        );
        $ctx->setTrailers([
            "endpoint-load-metrics-bin" => base64_encode($loadReport->marshalDc()),
        ]);
    }

    public function EmptyCall(\Grpcdc\CallContext $ctx, \EmptyPb\Empty_ $req): \EmptyPb\Empty_
    {
        return new \EmptyPb\Empty_();
    }

    public function UnaryCall(\Grpcdc\CallContext $ctx, \MessagesPb\SimpleRequest $req): \MessagesPb\SimpleResponse
    {
        $this->echoMetadata($ctx);
        if ($req->expectCompressed !== null && $req->expectCompressed->value
            && ($ctx->metadata["grpc-encoding"] ?? null) !== "gzip") {
            throw new \Grpcdc\StatusError(
                \Grpcdc\Wire::CODE_INVALID_ARGUMENT,
                "expected compressed request, got uncompressed"
            );
        }
        $this->checkStatus($req->responseStatus);
        if ($req->orcaPerQueryReport !== null) {
            $this->setOrcaTrailer($ctx, $req->orcaPerQueryReport);
        }
        return new \MessagesPb\SimpleResponse(
            new \MessagesPb\Payload($req->responseType, str_repeat("\0", $req->responseSize))
        );
    }

    // The official case sends two different payloads and expects
    // two different responses: echo the request payload back.
    public function CacheableUnaryCall(\Grpcdc\CallContext $ctx, \MessagesPb\SimpleRequest $req): \MessagesPb\SimpleResponse
    {
        $this->echoMetadata($ctx);
        return new \MessagesPb\SimpleResponse($req->payload);
    }

    public function StreamingOutputCall(\MessagesPb\StreamingOutputCallRequest $req, \TestGrpcDc\SendStream $stream): void
    {
        $this->echoMetadata($stream->context);
        $this->checkStatus($req->responseStatus);
        $this->sendResponses($req, $stream);
    }

    public function StreamingInputCall(\TestGrpcDc\ClientStreamImpl $stream): void
    {
        $this->echoMetadata($stream->context);
        $total = 0;
        try {
            while (true) {
                $req = $stream->recv();
                if ($req->expectCompressed !== null && $req->expectCompressed->value
                    && ($stream->context->metadata["grpc-encoding"] ?? null) !== "gzip") {
                    throw new \Grpcdc\StatusError(
                        \Grpcdc\Wire::CODE_INVALID_ARGUMENT,
                        "expected compressed request, got uncompressed"
                    );
                }
                if ($req->payload !== null) {
                    $total += strlen($req->payload->body);
                }
            }
        } catch (\Grpcdc\CallClosed $e) {
        }
        $stream->sendAndClose(new \MessagesPb\StreamingInputCallResponse($total));
    }

    public function FullDuplexCall(\TestGrpcDc\BidiStream $stream): void
    {
        $this->echoMetadata($stream->context);
        try {
            while (true) {
                $req = $stream->recv();
                $this->checkStatus($req->responseStatus);
                if ($req->orcaOobReport !== null) {
                    $report = $req->orcaOobReport;
                    self::$oobReport = new \OrcaLoadReportPb\OrcaLoadReport(
                        $report->cpuUtilization,
                        $report->memoryUtilization,
                        0.0,
                        $report->requestCost,
                        $report->utilization
                    );
                }
                $this->sendResponses($req, $stream);
            }
        } catch (\Grpcdc\CallClosed $e) {
        }
    }

    public function HalfDuplexCall(\TestGrpcDc\BidiStream $stream): void
    {
        $this->echoMetadata($stream->context);
        $collected = [];
        try {
            while (true) {
                $collected[] = $stream->recv();
            }
        } catch (\Grpcdc\CallClosed $e) {
        }
        foreach ($collected as $req) {
            $this->checkStatus($req->responseStatus);
            $this->sendResponses($req, $stream);
        }
    }

    public function UnimplementedCall(\Grpcdc\CallContext $ctx, \EmptyPb\Empty_ $req): \EmptyPb\Empty_
    {
        throw new \Grpcdc\StatusError(\Grpcdc\Wire::CODE_UNIMPLEMENTED, "not implemented");
    }

    // OpenRcaService (ORCA out-of-band): stream the current OOB
    // report on an interval until the client goes away.
    public function StreamCoreMetrics(\OrcaPb\OrcaLoadReportRequest $req, \OrcaGrpcDc\SendStream $stream): void
    {
        try {
            while (true) {
                $stream->send(self::$oobReport ?? new \OrcaLoadReportPb\OrcaLoadReport());
                usleep(200000);
                if ($this->pumpFn !== null) {
                    ($this->pumpFn)();
                }
            }
        } catch (\Grpcdc\StatusError | \Grpcdc\CallClosed $e) {
        }
    }
}
