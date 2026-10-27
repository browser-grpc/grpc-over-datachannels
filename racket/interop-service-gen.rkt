#lang racket

;;; interop-service-gen.rkt -- generated grpc.testing TestService
;;; implementations (INTEROP-GEN-SPEC.md rollout step 1: JS and
;;; Python). The behavior spec lives in interop-spec.rkt
;;; (interop-service-methods); each emitter stamps the shared
;;; semantics in the target language's generated-stub idiom.
;;; The two bodies mirror each other method for method; drift
;;; between them is what this file exists to prevent -- edit
;;; here, never in the generated outputs.

(require "interop-spec.rkt")
(provide emit-js-interop-service emit-py-interop-service emit-c-interop-service emit-cpp-interop-service emit-dart-interop-service)

;; metagen's write-runtime-files prepends the @generated header
;; for these extensions; emitters return (filename . body).

(define (emit-js-interop-service)
  (cons "interop_service.js"
   #<<ISGEN
// TestService implementation (grpc.testing) over our generated
// Server, mirroring the reference TestServiceImpl semantics the
// interop cases grade: payload sizes are answered with zero
// bodies of the requested size, response_parameters drive
// streamed responses (interval_us honored), response_status
// fails the call, streaming input is aggregated by byte count.
// Used by the Direction-B interop tests (official clients vs
// our servers).

import { StatusCode, StatusError } from "../index.js";
import { Empty } from "../examples/interop/empty_pb.js";
import {
  Payload,
  SimpleResponse,
  StreamingInputCallResponse,
  StreamingOutputCallResponse,
} from "../examples/interop/messages_pb.js";
import { OrcaLoadReport } from "../examples/interop/orca_load_report_pb.js";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const zeros = (n) => new Uint8Array(n);

// Reference echo (custom_metadata case): the echo-initial
// request value returns as initial metadata, the
// echo-trailing-bin value (base64 on our wire) as trailers.
function echoMetadata(ctx) {
  if (!ctx) return;
  const initial = ctx.metadata["x-grpc-test-echo-initial"];
  if (initial !== undefined) {
    ctx.setHeaders({ "x-grpc-test-echo-initial": initial });
  }
  const trailing = ctx.metadata["x-grpc-test-echo-trailing-bin"];
  if (trailing !== undefined) {
    ctx.setTrailers({ "x-grpc-test-echo-trailing-bin": trailing });
  }
}

// ORCA load reporting (orca_per_rpc / orca_oob): a per-request
// TestOrcaReport rides back as the serialized OrcaLoadReport in
// the `endpoint-load-metrics-bin` trailer; OOB reports carried
// by FullDuplexCall requests update shared state that later
// UnaryCalls report. The value is base64, exactly as -bin
// metadata values travel on both the grpc-dc wire and the
// HTTP/2 hops to stock clients.
let oobReport = null;

function setOrcaTrailer(ctx, fields) {
  if (!ctx || !fields) return;
  const bytes = OrcaLoadReport.encode(new OrcaLoadReport(fields));
  ctx.setTrailers({
    "endpoint-load-metrics-bin": Buffer.from(bytes).toString("base64"),
  });
}

// Compression interop (server direction): the proxy
// terminates gzip at the HTTP/2 hop and surfaces the declared
// encoding as ordinary metadata, so the reference checks map
// onto it -- expect_compressed fails when the request did not
// arrive compressed; response_compressed declares
// grpc-encoding: gzip in the initial metadata and the proxy
// gzips the response messages.
function compressionChecks(ctx, req) {
  if (req.expectCompressed?.value
      && ctx?.metadata?.["grpc-encoding"] !== "gzip") {
    throw new StatusError(
      StatusCode.INVALID_ARGUMENT,
      "expected compressed request, got uncompressed");
  }
  if (req.responseCompressed?.value) {
    ctx?.setHeaders?.({ "grpc-encoding": "gzip" });
  }
}

function maybeFail(req) {
  const status = req.responseStatus;
  if (status && (status.code !== 0 || status.message !== "")) {
    throw new StatusError(status.code, status.message);
  }
}

function unaryResponse(req) {
  maybeFail(req);
  return new SimpleResponse({
    payload: new Payload({ type: req.responseType, body: zeros(req.responseSize) }),
  });
}

async function* streamingResponses(req) {
  maybeFail(req);
  let first = true;
  for (const param of req.responseParameters) {
    if (!first && param.intervalUs > 0) await sleep(param.intervalUs / 1000);
    first = false;
    yield new StreamingOutputCallResponse({
      payload: new Payload({ type: req.responseType, body: zeros(param.size) }),
    });
  }
}

// OpenRcaService (ORCA out-of-band): stream the current OOB
// report on an interval until the client goes away.
export const openRcaHandlers = {
  async *streamCoreMetrics() {
    for (;;) {
      yield new OrcaLoadReport(oobReport ?? {});
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
  },
};

export const testServiceHandlers = {
  async emptyCall(req, ctx) {
    echoMetadata(ctx);
    return new Empty();
  },

  async unaryCall(req, ctx) {
    echoMetadata(ctx);
    compressionChecks(ctx, req);
    if (req.orcaPerQueryReport) {
      setOrcaTrailer(ctx, {
        cpuUtilization: req.orcaPerQueryReport.cpuUtilization,
        memUtilization: req.orcaPerQueryReport.memoryUtilization,
        requestCost: req.orcaPerQueryReport.requestCost,
        utilization: req.orcaPerQueryReport.utilization,
      });
    } else if (oobReport) {
      setOrcaTrailer(ctx, oobReport);
    }
    return unaryResponse(req);
  },

  async cacheableUnaryCall(req, ctx) {
    echoMetadata(ctx);
    // Reference semantics: echo the request payload (the case
    // asserts identical requests give identical responses and
    // differing requests differ).
    maybeFail(req);
    return new SimpleResponse({ payload: req.payload ?? new Payload() });
  },

  async *streamingOutputCall(req, ctx) {
    echoMetadata(ctx);
    yield* streamingResponses(req);
  },

  async streamingInputCall(requests, ctx) {
    echoMetadata(ctx);
    let total = 0;
    for await (const req of requests) {
      // Per-message expect_compressed, graded against the
      // stream's declared encoding (surfaced by the proxy
      // from the first message's compressed flag).
      if (req.expectCompressed?.value
          && ctx?.metadata?.["grpc-encoding"] !== "gzip") {
        throw new StatusError(
          StatusCode.INVALID_ARGUMENT,
          "expected compressed request, got uncompressed");
      }
      total += req.payload?.body.length ?? 0;
    }
    return new StreamingInputCallResponse({ aggregatedPayloadSize: total });
  },

  async *fullDuplexCall(requests, ctx) {
    echoMetadata(ctx);
    for await (const req of requests) {
      if (req.orcaOobReport) {
        oobReport = {
          cpuUtilization: req.orcaOobReport.cpuUtilization,
          memUtilization: req.orcaOobReport.memoryUtilization,
          utilization: req.orcaOobReport.utilization,
        };
      }
      yield* streamingResponses(req);
    }
  },

  async *halfDuplexCall(requests, ctx) {
    echoMetadata(ctx);
    const collected = [];
    for await (const req of requests) collected.push(req);
    for (const req of collected) {
      yield* streamingResponses(req);
    }
  },

  async unimplementedCall() {
    throw new StatusError(StatusCode.UNIMPLEMENTED, "not implemented");
  },
};
ISGEN
   ))
(define (emit-py-interop-service)
  (cons "interop_service.py"
   #<<ISGEN
"""TestService implementation (grpc.testing) over the generated
Python Server, mirroring the reference TestServiceImpl
semantics the interop cases grade: payload sizes answered
with zero bodies of the requested size, response_parameters
drive streamed responses (interval_us honored),
response_status fails the call, streaming input aggregated
by byte count. Used by test_interop_server_oracle.py.
"""

import base64
import threading
import time

import grpcdc
from grpcdc.wire_gen import CODE_INVALID_ARGUMENT, CODE_UNIMPLEMENTED
from messages_pb import (
    Payload,
    SimpleResponse,
    StreamingInputCallResponse,
    StreamingOutputCallResponse,
)
from orca_load_report_pb import OrcaLoadReport
from test_pb import Empty


def _zeros(n):
    return b"\x00" * n


def _maybe_fail(req):
    status = req.response_status
    if status is not None and (status.code != 0 or status.message != ""):
        raise grpcdc.StatusError(status.code, status.message)


def _echo_metadata(ctx):
    """Reference echo (custom_metadata case): the echo-initial
    request value returns as initial metadata, the
    echo-trailing-bin value (base64 on our wire) as trailers."""
    if ctx is None:
        return
    initial = ctx.metadata.get("x-grpc-test-echo-initial")
    if initial is not None:
        ctx.set_headers({"x-grpc-test-echo-initial": initial})
    trailing = ctx.metadata.get("x-grpc-test-echo-trailing-bin")
    if trailing is not None:
        ctx.set_trailers({"x-grpc-test-echo-trailing-bin": trailing})


# ORCA load reporting (orca_per_rpc / orca_oob): a per-request
# TestOrcaReport rides back as the serialized OrcaLoadReport in
# the endpoint-load-metrics-bin trailer (base64, as -bin values
# travel); OOB reports carried by FullDuplexCall requests update
# shared state that later UnaryCalls report.
_orca_lock = threading.Lock()
_orca_oob_report = None


def _set_orca_trailer(ctx, report):
    if ctx is None or report is None:
        return
    ctx.set_trailers({
        "endpoint-load-metrics-bin":
            base64.b64encode(report.marshal_dc()).decode("ascii"),
    })


def _compression_checks(ctx, req):
    # Compression interop (server direction): the proxy
    # terminates gzip at the HTTP/2 hop and surfaces the
    # declared encoding as ordinary metadata, so the reference
    # checks map onto it -- expect_compressed fails when the
    # request did not arrive compressed; response_compressed
    # declares grpc-encoding: gzip in the initial metadata and
    # the proxy gzips the response messages.
    if ctx is None:
        return
    if (req.expect_compressed is not None and req.expect_compressed.value
            and ctx.metadata.get("grpc-encoding") != "gzip"):
        raise grpcdc.StatusError(
            CODE_INVALID_ARGUMENT,
            "expected compressed request, got uncompressed")
    if (req.response_compressed is not None
            and req.response_compressed.value):
        ctx.set_headers({"grpc-encoding": "gzip"})


def _unary_response(req):
    _maybe_fail(req)
    return SimpleResponse(
        payload=Payload(type=req.response_type, body=_zeros(req.response_size))
    )


def _send_responses(req, send):
    _maybe_fail(req)
    for i, param in enumerate(req.response_parameters):
        if i > 0 and param.interval_us > 0:
            time.sleep(param.interval_us / 1_000_000)
        send(
            StreamingOutputCallResponse(
                payload=Payload(type=req.response_type, body=_zeros(param.size))
            )
        )


class OpenRcaServiceImpl:
    """ORCA out-of-band: stream the current OOB report on an
    interval until the client goes away."""

    def StreamCoreMetrics(self, req, stream):
        while True:
            with _orca_lock:
                report = _orca_oob_report
            stream.send(report if report is not None else OrcaLoadReport())
            time.sleep(0.2)


class TestServiceImpl:
    def EmptyCall(self, ctx, req):
        _echo_metadata(ctx)
        return Empty()

    def UnaryCall(self, ctx, req):
        _echo_metadata(ctx)
        _compression_checks(ctx, req)
        if req.orca_per_query_report is not None:
            r = req.orca_per_query_report
            _set_orca_trailer(ctx, OrcaLoadReport(
                cpu_utilization=r.cpu_utilization,
                mem_utilization=r.memory_utilization,
                request_cost=dict(r.request_cost),
                utilization=dict(r.utilization),
            ))
        else:
            global _orca_oob_report
            with _orca_lock:
                oob = _orca_oob_report
            _set_orca_trailer(ctx, oob)
        return _unary_response(req)

    def CacheableUnaryCall(self, ctx, req):
        _echo_metadata(ctx)
        # Reference semantics: echo the request payload.
        _maybe_fail(req)
        return SimpleResponse(payload=req.payload)

    def StreamingOutputCall(self, req, stream):
        _echo_metadata(stream.context)
        _send_responses(req, stream.send)

    def StreamingInputCall(self, stream):
        _echo_metadata(stream.context)
        total = 0
        while True:
            try:
                req = stream.recv()
            except EOFError:
                break
            # Per-message expect_compressed, graded against
            # the stream's declared encoding (surfaced by the
            # proxy from the first message's compressed flag).
            if (req.expect_compressed is not None
                    and req.expect_compressed.value
                    and stream.context.metadata.get("grpc-encoding") != "gzip"):
                raise grpcdc.StatusError(
                    CODE_INVALID_ARGUMENT,
                    "expected compressed request, got uncompressed")
            if req.payload is not None:
                total += len(req.payload.body)
        stream.send_and_close(
            StreamingInputCallResponse(aggregated_payload_size=total)
        )

    def FullDuplexCall(self, stream):
        _echo_metadata(stream.context)
        while True:
            try:
                req = stream.recv()
            except EOFError:
                return
            if req.orca_oob_report is not None:
                global _orca_oob_report
                r = req.orca_oob_report
                with _orca_lock:
                    _orca_oob_report = OrcaLoadReport(
                        cpu_utilization=r.cpu_utilization,
                        mem_utilization=r.memory_utilization,
                        utilization=dict(r.utilization),
                    )
            _send_responses(req, stream.send)

    def HalfDuplexCall(self, stream):
        _echo_metadata(stream.context)
        reqs = []
        while True:
            try:
                reqs.append(stream.recv())
            except EOFError:
                break
        for req in reqs:
            _send_responses(req, stream.send)

    def UnimplementedCall(self, ctx, req):
        raise grpcdc.StatusError(CODE_UNIMPLEMENTED, "not implemented")
ISGEN
   ))

(define (emit-c-interop-service)
  (cons "interop_service_impl.h"
   #<<ISGEN
#pragma once
/* TestService implementation (grpc.testing) over the generated
   C server, mirroring the reference TestServiceImpl semantics
   the interop cases grade. Used by the Direction-B interop tests
   (official clients vs generated servers). Mirrors
   js/test/interop_service.js. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void isvc_sleep_us(long us) {
    struct timespec ts;
    ts.tv_sec = us / 1000000;
    ts.tv_nsec = (us % 1000000) * 1000;
    nanosleep(&ts, NULL);
}

#include "test_grpc_dc.h"
#include "orca_grpc_dc.h"

static const char *isvc_md_get(const grpcdc_kv *md, size_t md_count, const char *key) {
    for (size_t i = 0; i < md_count; i++)
        if (strcmp(md[i].key, key) == 0) return md[i].value;
    return NULL;
}

/* Latest ORCA out-of-band report (full-duplex updates). */
static OrcaLoadReport isvc_oob_report;
static int isvc_oob_set = 0;

/* Base64 buffer for the endpoint-load-metrics-bin trailer:
   the status/headers carriers borrow value pointers, so the
   encoded text lives in process-static storage. */
static char *isvc_orca_b64 = NULL;
static size_t isvc_orca_b64_cap = 0;

static const char *isvc_orca_b64_encode(const uint8_t *data, size_t len) {
    static const char tab[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t need = 4 * ((len + 2) / 3) + 1;
    if (need > isvc_orca_b64_cap) {
        isvc_orca_b64 = (char *)realloc(isvc_orca_b64, need);
        isvc_orca_b64_cap = need;
    }
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)data[i] << 16;
        int rem = (int)(len - i);
        if (rem > 1) v |= (uint32_t)data[i + 1] << 8;
        if (rem > 2) v |= data[i + 2];
        isvc_orca_b64[o++] = tab[(v >> 18) & 63];
        isvc_orca_b64[o++] = tab[(v >> 12) & 63];
        isvc_orca_b64[o++] = rem > 1 ? tab[(v >> 6) & 63] : '=';
        isvc_orca_b64[o++] = rem > 2 ? tab[v & 63] : '=';
    }
    isvc_orca_b64[o] = 0;
    return isvc_orca_b64;
}

/* Echo interop metadata into status-carried headers/trailers
   (unary / client-streaming shape). */
static void isvc_echo_md_status(grpcdc_status *st, const grpcdc_kv *md, size_t md_count) {
    const char *initial = isvc_md_get(md, md_count, "x-grpc-test-echo-initial");
    if (initial) {
        st->headers[st->headers_count].key = "x-grpc-test-echo-initial";
        st->headers[st->headers_count].value = initial;
        st->headers_count++;
    }
    const char *trailing = isvc_md_get(md, md_count, "x-grpc-test-echo-trailing-bin");
    if (trailing) {
        st->trailers[st->trailers_count].key = "x-grpc-test-echo-trailing-bin";
        st->trailers[st->trailers_count].value = trailing;
        st->trailers_count++;
    }
}

/* Echo interop metadata through a server stream (streaming
   shape: initial rides HEADERS, trailing rides the status). */
static void isvc_echo_md_stream(grpcdc_server_stream *raw) {
    const grpcdc_kv *md;
    size_t md_count;
    grpcdc_server_stream_metadata(raw, &md, &md_count);
    const char *initial = isvc_md_get(md, md_count, "x-grpc-test-echo-initial");
    if (initial)
        grpcdc_server_stream_set_header(raw, "x-grpc-test-echo-initial", initial);
    const char *trailing = isvc_md_get(md, md_count, "x-grpc-test-echo-trailing-bin");
    if (trailing)
        grpcdc_server_stream_set_trailer(raw, "x-grpc-test-echo-trailing-bin", trailing);
}

static const grpcdc_kv *isvc_stream_md(grpcdc_server_stream *raw, size_t *count) {
    const grpcdc_kv *md;
    grpcdc_server_stream_metadata(raw, &md, count);
    return md;
}

/* Compression interop (server direction): the bridge
   terminates gzip at the HTTP/2 hop and surfaces the declared
   encoding as ordinary metadata. */
static grpcdc_status isvc_compression_checks(grpcdc_status *st, const grpcdc_kv *md,
                                             size_t md_count,
                                             const BoolValue *expect_compressed,
                                             const BoolValue *response_compressed) {
    if (expect_compressed && expect_compressed->value) {
        const char *enc = isvc_md_get(md, md_count, "grpc-encoding");
        if (!enc || strcmp(enc, "gzip") != 0)
            return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                      "expected compressed request, got uncompressed");
    }
    if (response_compressed && response_compressed->value) {
        st->headers[st->headers_count].key = "grpc-encoding";
        st->headers[st->headers_count].value = "gzip";
        st->headers_count++;
    }
    return grpcdc_ok();
}

static grpcdc_status isvc_maybe_fail(const EchoStatus *status) {
    if (status && (status->code != 0 || (status->message && status->message[0])))
        return grpcdc_status_make(status->code, status->message);
    return grpcdc_ok();
}

static Payload *isvc_payload(PayloadType type, int32_t size) {
    Payload *p = (Payload *)calloc(1, sizeof(Payload));
    p->type = type;
    size_t n = size < 0 ? 0 : (size_t)size;
    p->body.data = (uint8_t *)calloc(n ? n : 1, 1);
    p->body.len = n;
    return p;
}

static grpcdc_status isvc_unary_response(const SimpleRequest *req, SimpleResponse *resp) {
    grpcdc_status st = isvc_maybe_fail(req->response_status);
    if (!grpcdc_status_is_ok(st)) return st;
    memset(resp, 0, sizeof(*resp));
    resp->payload = isvc_payload(req->response_type, req->response_size);
    return grpcdc_ok();
}

static void isvc_set_orca_trailer(grpcdc_status *st, const OrcaLoadReport *report) {
    Orca_load_reportPbBytes bytes = OrcaLoadReport_marshal(report);
    const char *encoded = isvc_orca_b64_encode(bytes.data, bytes.len);
    free(bytes.data);
    st->trailers[st->trailers_count].key = "endpoint-load-metrics-bin";
    st->trailers[st->trailers_count].value = encoded;
    st->trailers_count++;
}

static void isvc_orca_from_test_report(OrcaLoadReport *out, const TestOrcaReport *report,
                                       int with_cost) {
    memset(out, 0, sizeof(*out));
    out->cpu_utilization = report->cpu_utilization;
    out->mem_utilization = report->memory_utilization;
    if (with_cost) {
        out->request_cost_count = report->request_cost_count;
        out->request_cost = (OrcaLoadReport_RequestCostEntry *)calloc(
            report->request_cost_count ? report->request_cost_count : 1,
            sizeof(OrcaLoadReport_RequestCostEntry));
        for (size_t i = 0; i < report->request_cost_count; i++) {
            out->request_cost[i].key = report->request_cost[i].key;
            out->request_cost[i].value = report->request_cost[i].value;
        }
    }
    out->utilization_count = report->utilization_count;
    out->utilization = (OrcaLoadReport_UtilizationEntry *)calloc(
        report->utilization_count ? report->utilization_count : 1,
        sizeof(OrcaLoadReport_UtilizationEntry));
    for (size_t i = 0; i < report->utilization_count; i++) {
        out->utilization[i].key = report->utilization[i].key;
        out->utilization[i].value = report->utilization[i].value;
    }
}

static grpcdc_status isvc_empty_call(void *ctx, const grpcdc_kv *md, size_t md_count,
                                     const Empty *req, Empty *resp) {
    (void)ctx;
    (void)req;
    (void)resp;
    grpcdc_status st = grpcdc_ok();
    isvc_echo_md_status(&st, md, md_count);
    return st;
}

static grpcdc_status isvc_unary_call(void *ctx, const grpcdc_kv *md, size_t md_count,
                                     const SimpleRequest *req, SimpleResponse *resp) {
    (void)ctx;
    grpcdc_status st = grpcdc_ok();
    isvc_echo_md_status(&st, md, md_count);
    grpcdc_status cst = isvc_compression_checks(&st, md, md_count,
                                                req->expect_compressed,
                                                req->response_compressed);
    if (!grpcdc_status_is_ok(cst)) return cst;
    if (req->orca_per_query_report) {
        OrcaLoadReport report;
        isvc_orca_from_test_report(&report, req->orca_per_query_report, 1);
        isvc_set_orca_trailer(&st, &report);
    } else if (isvc_oob_set) {
        isvc_set_orca_trailer(&st, &isvc_oob_report);
    }
    grpcdc_status ust = isvc_unary_response(req, resp);
    if (!grpcdc_status_is_ok(ust)) return ust;
    /* Preserve echo/orca metadata gathered above. */
    ust.headers_count = st.headers_count;
    for (size_t i = 0; i < st.headers_count; i++) ust.headers[i] = st.headers[i];
    ust.trailers_count = st.trailers_count;
    for (size_t i = 0; i < st.trailers_count; i++) ust.trailers[i] = st.trailers[i];
    return ust;
}

static grpcdc_status isvc_cacheable_unary_call(void *ctx, const grpcdc_kv *md,
                                               size_t md_count,
                                               const SimpleRequest *req,
                                               SimpleResponse *resp) {
    (void)ctx;
    grpcdc_status st = grpcdc_ok();
    isvc_echo_md_status(&st, md, md_count);
    grpcdc_status fst = isvc_maybe_fail(req->response_status);
    if (!grpcdc_status_is_ok(fst)) return fst;
    memset(resp, 0, sizeof(*resp));
    resp->payload = req->payload ? req->payload : isvc_payload(req->response_type, 0);
    return st;
}

typedef grpcdc_status (*isvc_send_fn)(void *stream, const StreamingOutputCallResponse *resp);

/* Sleep for an interop response interval in 10ms slices,
   aborting when the client cancels: the C serve loop is
   single-stream, so an uninterruptible sleep would wedge
   every later call behind a dead one. */
static int isvc_sleep_interval(grpcdc_server_stream *raw, int32_t interval_us,
                               int first) {
    if (first || interval_us <= 0) return 0;
    long remaining = interval_us;
    while (remaining > 0) {
        long slice = remaining > 10000 ? 10000 : remaining;
        isvc_sleep_us(slice);
        remaining -= slice;
        if (grpcdc_server_stream_cancelled(raw)) return 1;
    }
    return 0;
}

static grpcdc_status isvc_send_responses(const StreamingOutputCallRequest *req,
                                         void *stream, isvc_send_fn send,
                                         grpcdc_server_stream *raw) {
    grpcdc_status fst = isvc_maybe_fail(req->response_status);
    if (!grpcdc_status_is_ok(fst)) return fst;
    int first = 1;
    for (size_t i = 0; i < req->response_parameters_count; i++) {
        const ResponseParameters *param = &req->response_parameters[i];
        if (isvc_sleep_interval(raw, param->interval_us, first))
            return grpcdc_status_make(GRPCDC_CANCELLED, "call cancelled");
        first = 0;
        StreamingOutputCallResponse resp;
        memset(&resp, 0, sizeof(resp));
        resp.payload = isvc_payload(req->response_type, param->size);
        grpcdc_status st = send(stream, &resp);
        if (!grpcdc_status_is_ok(st)) return st;
    }
    return grpcdc_ok();
}

static grpcdc_status isvc_send_output_stream(void *stream,
                                             const StreamingOutputCallResponse *resp) {
    return TestServiceStreamingOutputCallStream_send(
        (TestServiceStreamingOutputCallStream *)stream, resp);
}

static grpcdc_status isvc_streaming_output_call(void *ctx, const grpcdc_kv *md,
                                                size_t md_count,
                                                const StreamingOutputCallRequest *req,
                                                TestServiceStreamingOutputCallStream *stream) {
    (void)ctx;
    (void)md;
    (void)md_count;
    isvc_echo_md_stream(stream->raw);
    return isvc_send_responses(req, stream, isvc_send_output_stream, stream->raw);
}

static grpcdc_status isvc_streaming_input_call(void *ctx,
                                               TestServiceStreamingInputCallStream *stream,
                                               StreamingInputCallResponse *resp) {
    (void)ctx;
    isvc_echo_md_stream(stream->raw);
    size_t md_count = 0;
    const grpcdc_kv *md = isvc_stream_md(stream->raw, &md_count);
    int32_t total = 0;
    while (1) {
        StreamingInputCallRequest req;
        grpcdc_status rst;
        int r = TestServiceStreamingInputCallStream_recv(stream, &req, &rst);
        if (r == 0) break;
        if (r < 0) return rst;
        if (req.expect_compressed && req.expect_compressed->value) {
            const char *enc = isvc_md_get(md, md_count, "grpc-encoding");
            if (!enc || strcmp(enc, "gzip") != 0)
                return grpcdc_status_make(GRPCDC_INVALID_ARGUMENT,
                                          "expected compressed request, got uncompressed");
        }
        if (req.payload) total += (int32_t)req.payload->body.len;
    }
    memset(resp, 0, sizeof(*resp));
    resp->aggregated_payload_size = total;
    return grpcdc_ok();
}

static grpcdc_status isvc_send_full_duplex(void *stream,
                                           const StreamingOutputCallResponse *resp) {
    return TestServiceFullDuplexCallStream_send(
        (TestServiceFullDuplexCallStream *)stream, resp);
}

static grpcdc_status isvc_full_duplex_call(void *ctx,
                                           TestServiceFullDuplexCallStream *stream) {
    (void)ctx;
    isvc_echo_md_stream(stream->raw);
    while (1) {
        StreamingOutputCallRequest req;
        grpcdc_status rst;
        int r = TestServiceFullDuplexCallStream_recv(stream, &req, &rst);
        if (r == 0) return grpcdc_ok();
        if (r < 0) return rst;
        if (req.orca_oob_report) {
            isvc_orca_from_test_report(&isvc_oob_report, req.orca_oob_report, 0);
            isvc_oob_set = 1;
        }
        grpcdc_status st = isvc_send_responses(&req, stream, isvc_send_full_duplex, stream->raw);
        if (!grpcdc_status_is_ok(st)) return st;
    }
}

static grpcdc_status isvc_send_half_duplex(void *stream,
                                           const StreamingOutputCallResponse *resp) {
    return TestServiceHalfDuplexCallStream_send(
        (TestServiceHalfDuplexCallStream *)stream, resp);
}

static grpcdc_status isvc_half_duplex_call(void *ctx,
                                           TestServiceHalfDuplexCallStream *stream) {
    (void)ctx;
    isvc_echo_md_stream(stream->raw);
    size_t cap = 4, count = 0;
    StreamingOutputCallRequest *collected =
        (StreamingOutputCallRequest *)calloc(cap, sizeof(StreamingOutputCallRequest));
    while (1) {
        StreamingOutputCallRequest req;
        grpcdc_status rst;
        int r = TestServiceHalfDuplexCallStream_recv(stream, &req, &rst);
        if (r == 0) break;
        if (r < 0) {
            free(collected);
            return rst;
        }
        if (count == cap) {
            cap *= 2;
            collected = (StreamingOutputCallRequest *)realloc(
                collected, cap * sizeof(StreamingOutputCallRequest));
        }
        collected[count++] = req;
    }
    for (size_t i = 0; i < count; i++) {
        grpcdc_status st = isvc_send_responses(&collected[i], stream, isvc_send_half_duplex, stream->raw);
        if (!grpcdc_status_is_ok(st)) {
            free(collected);
            return st;
        }
    }
    free(collected);
    return grpcdc_ok();
}

static grpcdc_status isvc_unimplemented_call(void *ctx, const grpcdc_kv *md,
                                             size_t md_count, const Empty *req,
                                             Empty *resp) {
    (void)ctx;
    (void)md;
    (void)md_count;
    (void)req;
    (void)resp;
    return grpcdc_status_make(GRPCDC_UNIMPLEMENTED, "not implemented");
}

static grpcdc_status isvc_stream_core_metrics(void *ctx, const grpcdc_kv *md,
                                              size_t md_count,
                                              const OrcaLoadReportRequest *req,
                                              OpenRcaServiceStreamCoreMetricsStream *stream) {
    (void)ctx;
    (void)md;
    (void)md_count;
    (void)req;
    /* OpenRcaService (ORCA out-of-band): send the current OOB
       report once and close. The generated C server serves one
       stream at a time, so an endless metrics stream would
       starve every other call on the connection (the official
       clients' ORCA load balancer holds this stream open
       concurrently with the RPCs it grades); a one-shot report
       is legal ORCA and the balancer reopens the stream when
       it wants another. */
    {
        OrcaLoadReport report;
        memset(&report, 0, sizeof(report));
        if (isvc_oob_set) report = isvc_oob_report;
        return OpenRcaServiceStreamCoreMetricsStream_send(stream, &report);
    }
}

static TestServiceServerImpl isvc_test_service = {
    NULL,
    isvc_empty_call,
    isvc_unary_call,
    isvc_cacheable_unary_call,
    isvc_streaming_output_call,
    isvc_streaming_input_call,
    isvc_full_duplex_call,
    isvc_half_duplex_call,
    isvc_unimplemented_call,
};

static OpenRcaServiceServerImpl isvc_open_rca = {
    NULL,
    isvc_stream_core_metrics,
};
ISGEN
   ))

(define (emit-cpp-interop-service)
  (cons "interop_service_impl.hpp"
   #<<ISGEN
#pragma once
// TestService implementation (grpc.testing) over the generated
// C++ server, mirroring the reference TestServiceImpl semantics
// the interop cases grade. Used by the Direction-B interop tests
// (official clients vs generated servers). Mirrors
// js/test/interop_service.js.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "examples/messages_messages.hpp"
#include "examples/orca_grpc_dc.hpp"
#include "examples/orca_load_report_messages.hpp"
#include "examples/test_grpc_dc.hpp"
#include "grpcdc/endpoint.hpp"
#include "grpcdc/status.hpp"

namespace grpc::testing {

class InteropServiceImpl : public TestGrpcDc::TestServiceServer,
                           public xds::service::orca::v3::OrcaGrpcDc::OpenRcaServiceServer {
 public:
  // Latest ORCA out-of-band report (full-duplex updates).
  inline static xds::data::orca::v3::OrcaLoadReport* oob_report = nullptr;

  Empty EmptyCall(grpcdc::Endpoint::CallContext& ctx, Empty& req) override {
    EchoMetadata(ctx);
    return Empty();
  }

  SimpleResponse UnaryCall(grpcdc::Endpoint::CallContext& ctx,
                           SimpleRequest& req) override {
    EchoMetadata(ctx);
    CompressionChecks(ctx, OptPtr(req.expect_compressed), OptPtr(req.response_compressed));
    if (req.orca_per_query_report) {
      const TestOrcaReport& report = *req.orca_per_query_report;
      xds::data::orca::v3::OrcaLoadReport out;
      out.cpu_utilization = report.cpu_utilization;
      out.mem_utilization = report.memory_utilization;
      out.request_cost = report.request_cost;
      out.utilization = report.utilization;
      SetOrcaTrailer(ctx, out);
    } else if (oob_report != nullptr) {
      SetOrcaTrailer(ctx, *oob_report);
    }
    return UnaryResponse(req);
  }

  SimpleResponse CacheableUnaryCall(grpcdc::Endpoint::CallContext& ctx,
                                    SimpleRequest& req) override {
    EchoMetadata(ctx);
    MaybeFail(OptPtr(req.response_status));
    SimpleResponse resp;
    resp.payload = req.payload;
    return resp;
  }

  void StreamingOutputCall(StreamingOutputCallRequest& req,
                           TestGrpcDc::TestServiceStreamingOutputCallServer& stream) override {
    EchoMetadata(stream.Context());
    SendResponses(req, [&](StreamingOutputCallResponse& resp) { stream.Send(resp); });
  }

  void StreamingInputCall(TestGrpcDc::TestServiceStreamingInputCallServer& stream) override {
    EchoMetadata(stream.Context());
    std::int32_t total = 0;
    while (true) {
      StreamingInputCallRequest req;
      try {
        req = stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        break;
      }
      if (req.expect_compressed && req.expect_compressed->value &&
          MetadataGet(stream.Context().metadata, "grpc-encoding") != "gzip") {
        throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                      "expected compressed request, got uncompressed");
      }
      if (req.payload) total += static_cast<std::int32_t>(req.payload->body.size());
    }
    StreamingInputCallResponse resp;
    resp.aggregated_payload_size = total;
    stream.SendAndClose(resp);
  }

  void FullDuplexCall(TestGrpcDc::TestServiceFullDuplexCallServer& stream) override {
    EchoMetadata(stream.Context());
    while (true) {
      StreamingOutputCallRequest req;
      try {
        req = stream.Recv();
      } catch (const grpcdc::EndOfStream&) {
        return;
      }
      if (req.orca_oob_report) {
        auto* out = new xds::data::orca::v3::OrcaLoadReport();
        out->cpu_utilization = req.orca_oob_report->cpu_utilization;
        out->mem_utilization = req.orca_oob_report->memory_utilization;
        out->utilization = req.orca_oob_report->utilization;
        delete oob_report;
        oob_report = out;
      }
      SendResponses(req, [&](StreamingOutputCallResponse& resp) { stream.Send(resp); });
    }
  }

  void HalfDuplexCall(TestGrpcDc::TestServiceHalfDuplexCallServer& stream) override {
    EchoMetadata(stream.Context());
    std::vector<StreamingOutputCallRequest> collected;
    while (true) {
      try {
        collected.push_back(stream.Recv());
      } catch (const grpcdc::EndOfStream&) {
        break;
      }
    }
    for (const auto& req : collected) {
      SendResponses(req, [&](StreamingOutputCallResponse& resp) { stream.Send(resp); });
    }
  }

  Empty UnimplementedCall(grpcdc::Endpoint::CallContext& ctx, Empty& req) override {
    throw grpcdc::StatusException(grpcdc::wire::kCodeUnimplemented, "not implemented");
  }

  // OpenRcaService (ORCA out-of-band): stream the current OOB
  // report on an interval until the client goes away.
  void StreamCoreMetrics(xds::service::orca::v3::OrcaLoadReportRequest& req,
                         xds::service::orca::v3::OrcaGrpcDc::OpenRcaServiceStreamCoreMetricsServer& stream) override {
    while (true) {
      xds::data::orca::v3::OrcaLoadReport empty;
      stream.Send(oob_report != nullptr ? *oob_report : empty);
      std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
  }

 private:
  static const std::string* MetadataFind(const grpcdc::Metadata& md, const std::string& key) {
    auto it = md.find(key);
    return it == md.end() ? nullptr : &it->second;
  }

  static std::string MetadataGet(const grpcdc::Metadata& md, const std::string& key) {
    const std::string* v = MetadataFind(md, key);
    return v != nullptr ? *v : "";
  }

  static std::string Base64Encode(const grpcdc::Bytes& data) {
    static const char* kTab =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    for (std::size_t i = 0; i < data.size(); i += 3) {
      std::uint32_t v = static_cast<std::uint32_t>(data[i]) << 16;
      std::size_t rem = data.size() - i;
      if (rem > 1) v |= static_cast<std::uint32_t>(data[i + 1]) << 8;
      if (rem > 2) v |= data[i + 2];
      out.push_back(kTab[(v >> 18) & 63]);
      out.push_back(kTab[(v >> 12) & 63]);
      out.push_back(rem > 1 ? kTab[(v >> 6) & 63] : '=');
      out.push_back(rem > 2 ? kTab[v & 63] : '=');
    }
    return out;
  }

  template <typename T>
  static const T* OptPtr(const std::optional<T>& v) {
    return v ? &*v : nullptr;
  }

  static Payload MakePayload(PayloadType type, std::int32_t size) {
    Payload payload;
    payload.type = type;
    payload.body.assign(static_cast<std::size_t>(std::max(0, size)), 0);
    return payload;
  }

  static void EchoMetadata(const grpcdc::Endpoint::CallContext& ctx) {
    if (const std::string* initial = MetadataFind(ctx.metadata, "x-grpc-test-echo-initial")) {
      ctx.SetHeaders({{"x-grpc-test-echo-initial", *initial}});
    }
    if (const std::string* trailing = MetadataFind(ctx.metadata, "x-grpc-test-echo-trailing-bin")) {
      ctx.SetTrailers({{"x-grpc-test-echo-trailing-bin", *trailing}});
    }
  }

  static void SetOrcaTrailer(const grpcdc::Endpoint::CallContext& ctx,
                             const xds::data::orca::v3::OrcaLoadReport& report) {
    ctx.SetTrailers({{"endpoint-load-metrics-bin", Base64Encode(report.MarshalDc())}});
  }

  // Compression interop (server direction): the bridge
  // terminates gzip at the HTTP/2 hop and surfaces the
  // declared encoding as ordinary metadata.
  static void CompressionChecks(const grpcdc::Endpoint::CallContext& ctx,
                                const BoolValue* expect_compressed,
                                const BoolValue* response_compressed) {
    if (expect_compressed != nullptr && expect_compressed->value &&
        MetadataGet(ctx.metadata, "grpc-encoding") != "gzip") {
      throw grpcdc::StatusException(grpcdc::wire::kCodeInvalidArgument,
                                    "expected compressed request, got uncompressed");
    }
    if (response_compressed != nullptr && response_compressed->value) {
      ctx.SetHeaders({{"grpc-encoding", "gzip"}});
    }
  }

  static void MaybeFail(const EchoStatus* status) {
    if (status != nullptr && (status->code != 0 || !status->message.empty())) {
      throw grpcdc::StatusException(status->code, status->message);
    }
  }

  static SimpleResponse UnaryResponse(const SimpleRequest& req) {
    MaybeFail(OptPtr(req.response_status));
    SimpleResponse resp;
    resp.payload = MakePayload(req.response_type, req.response_size);
    return resp;
  }

  template <typename SendFn>
  static void SendResponses(const StreamingOutputCallRequest& req, SendFn&& send) {
    MaybeFail(OptPtr(req.response_status));
    bool first = true;
    for (const auto& param : req.response_parameters) {
      if (!first && param.interval_us > 0) {
        std::this_thread::sleep_for(std::chrono::microseconds(param.interval_us));
      }
      first = false;
      StreamingOutputCallResponse resp;
      resp.payload = MakePayload(req.response_type, param.size);
      send(resp);
    }
  }
};

}  // namespace grpc::testing
ISGEN
   ))

(define (emit-dart-interop-service)
  (cons "interop_service_impl.dart"
   #<<ISGEN
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../grpcdc/endpoint.dart';
import '../grpcdc/status.dart';
import '../grpcdc/wire.dart';
import 'empty_messages.dart';
import 'messages_messages.dart';
import 'orca_grpc_dc.dart';
import 'orca_load_report_messages.dart';
import 'orca_messages.dart';
import 'test_grpc_dc.dart';

/// TestService implementation (grpc.testing) over the generated
/// Server, mirroring the reference TestServiceImpl semantics the
/// interop cases grade. Used by the Direction-B interop tests
/// (official clients vs generated servers). Mirrors
/// js/test/interop_service.js.
class InteropServiceImpl implements TestServiceServer, OpenRcaServiceServer {
  /// Latest ORCA out-of-band report (full-duplex updates).
  static OrcaLoadReport? oobReport;

  void _echoMetadata(CallContext ctx) {
    final initial = ctx.metadata['x-grpc-test-echo-initial'];
    if (initial != null) {
      ctx.setHeaders({'x-grpc-test-echo-initial': initial});
    }
    final trailing = ctx.metadata['x-grpc-test-echo-trailing-bin'];
    if (trailing != null) {
      ctx.setTrailers({'x-grpc-test-echo-trailing-bin': trailing});
    }
  }

  void _setOrcaTrailer(CallContext ctx, OrcaLoadReport report) {
    ctx.setTrailers({
      'endpoint-load-metrics-bin': base64Encode(report.marshalDc()),
    });
  }

  // Compression interop (server direction): the bridge
  // terminates gzip at the HTTP/2 hop and surfaces the
  // declared encoding as ordinary metadata.
  void _compressionChecks(CallContext ctx, BoolValue? expectCompressed,
      BoolValue? responseCompressed) {
    if (expectCompressed != null &&
        expectCompressed.value &&
        ctx.metadata['grpc-encoding'] != 'gzip') {
      throw StatusException(Wire.codeInvalidArgument,
          'expected compressed request, got uncompressed');
    }
    if (responseCompressed != null && responseCompressed.value) {
      ctx.setHeaders({'grpc-encoding': 'gzip'});
    }
  }

  void _maybeFail(EchoStatus? status) {
    if (status != null && (status.code != 0 || status.message.isNotEmpty)) {
      throw StatusException(status.code, status.message);
    }
  }

  SimpleResponse _unaryResponse(SimpleRequest req) {
    _maybeFail(req.responseStatus);
    final resp = SimpleResponse();
    resp.payload = Payload(req.responseType)
      ..body = Uint8List(req.responseSize < 0 ? 0 : req.responseSize);
    return resp;
  }

  Future<void> _sendResponses(StreamingOutputCallRequest req,
      void Function(StreamingOutputCallResponse) send) async {
    _maybeFail(req.responseStatus);
    var first = true;
    for (final param in req.responseParameters) {
      if (!first && param.intervalUs > 0) {
        await Future.delayed(Duration(microseconds: param.intervalUs));
      }
      first = false;
      send(StreamingOutputCallResponse(Payload(req.responseType)
        ..body = Uint8List(param.size < 0 ? 0 : param.size)));
    }
  }

  @override
  Future<Empty> emptyCall(CallContext ctx, Empty req) async {
    _echoMetadata(ctx);
    return Empty();
  }

  @override
  Future<SimpleResponse> unaryCall(CallContext ctx, SimpleRequest req) async {
    _echoMetadata(ctx);
    _compressionChecks(ctx, req.expectCompressed, req.responseCompressed);
    final perQuery = req.orcaPerQueryReport;
    if (perQuery != null) {
      _setOrcaTrailer(
          ctx,
          OrcaLoadReport(perQuery.cpuUtilization, perQuery.memoryUtilization, 0)
            ..requestCost = perQuery.requestCost
            ..utilization = perQuery.utilization);
    } else if (oobReport != null) {
      _setOrcaTrailer(ctx, oobReport!);
    }
    return _unaryResponse(req);
  }

  @override
  Future<SimpleResponse> cacheableUnaryCall(
      CallContext ctx, SimpleRequest req) async {
    _echoMetadata(ctx);
    _maybeFail(req.responseStatus);
    final resp = SimpleResponse();
    resp.payload = req.payload ?? Payload();
    return resp;
  }

  @override
  Future<void> streamingOutputCall(StreamingOutputCallRequest req,
      TestServiceStreamingOutputCallServer stream) async {
    _echoMetadata(stream.context);
    await _sendResponses(req, stream.send);
  }

  @override
  Future<void> streamingInputCall(
      TestServiceStreamingInputCallServer stream) async {
    _echoMetadata(stream.context);
    var total = 0;
    while (true) {
      final StreamingInputCallRequest req;
      try {
        req = await stream.recv();
      } on EndOfStreamError {
        break;
      }
      if (req.expectCompressed != null &&
          req.expectCompressed!.value &&
          stream.context.metadata['grpc-encoding'] != 'gzip') {
        throw StatusException(Wire.codeInvalidArgument,
            'expected compressed request, got uncompressed');
      }
      total += req.payload?.body.length ?? 0;
    }
    stream.sendAndClose(StreamingInputCallResponse(total));
  }

  @override
  Future<void> fullDuplexCall(TestServiceFullDuplexCallServer stream) async {
    _echoMetadata(stream.context);
    while (true) {
      final StreamingOutputCallRequest req;
      try {
        req = await stream.recv();
      } on EndOfStreamError {
        return;
      }
      final oob = req.orcaOobReport;
      if (oob != null) {
        oobReport = OrcaLoadReport(oob.cpuUtilization, oob.memoryUtilization, 0)
          ..utilization = oob.utilization;
      }
      await _sendResponses(req, stream.send);
    }
  }

  @override
  Future<void> halfDuplexCall(TestServiceHalfDuplexCallServer stream) async {
    _echoMetadata(stream.context);
    final collected = <StreamingOutputCallRequest>[];
    while (true) {
      try {
        collected.add(await stream.recv());
      } on EndOfStreamError {
        break;
      }
    }
    for (final req in collected) {
      await _sendResponses(req, stream.send);
    }
  }

  @override
  Future<Empty> unimplementedCall(CallContext ctx, Empty req) async {
    throw StatusException(Wire.codeUnimplemented, 'not implemented');
  }

  // OpenRcaService (ORCA out-of-band): stream the current OOB
  // report on an interval until the client goes away.
  @override
  Future<void> streamCoreMetrics(
      OrcaLoadReportRequest req, OpenRcaServiceStreamCoreMetricsServer stream) async {
    while (true) {
      stream.send(oobReport ?? OrcaLoadReport());
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }
}
ISGEN
   ))
