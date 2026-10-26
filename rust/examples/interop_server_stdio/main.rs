//! Interop harness: grpc.testing.TestService + xds ORCA
//! OpenRcaService over the generated Rust Server, stdio
//! transport. Spawned by the bridge (`bridge.mjs http2-to-dc
//! --target-cmd`) so the official grpc-java interop client can
//! grade this server through the proxy; see
//! rust/tests/interop_oracle.rs.
//!
//! Semantics mirror python/tests/interop_service.py (the
//! reference TestServiceImpl behavior the interop cases grade).

#[path = "pb_glue.rs"]
mod pb;

#[path = "../../gen/test_grpc_dc.rs"]
mod test_stub;

#[path = "../../gen/orca_grpc_dc.rs"]
mod orca_stub;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::{Stream, StreamExt, TryStreamExt};
use grpc_dc::{
    CallCtx, DcTransport, Metadata, RequestStream, ResponseStream, Server, Status,
};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct StdioDc {
    tx: tokio::sync::Mutex<tokio::io::Stdout>,
    rx: tokio::sync::Mutex<tokio::io::Stdin>,
}

#[async_trait]
impl DcTransport for StdioDc {
    async fn send(&self, msg: Bytes) -> Result<(), Status> {
        let mut tx = self.tx.lock().await;
        tx.write_u32(msg.len() as u32)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.write_all(&msg)
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        tx.flush()
            .await
            .map_err(|e| Status::unavailable(format!("stdio write: {e}")))?;
        Ok(())
    }

    async fn next(&self) -> Option<Result<Bytes, Status>> {
        let mut rx = self.rx.lock().await;
        let len = match rx.read_u32().await {
            Ok(n) => n as usize,
            Err(_) => return None,
        };
        let mut buf = vec![0u8; len];
        match rx.read_exact(&mut buf).await {
            Ok(_) => Some(Ok(Bytes::from(buf))),
            Err(e) => Some(Err(Status::unavailable(format!("stdio read: {e}")))),
        }
    }
}

fn maybe_fail(status: &Option<Box<pb::EchoStatus>>) -> Result<(), Status> {
    if let Some(s) = status {
        if s.code != 0 || !s.message.is_empty() {
            return Err(Status::from_code_u32(s.code as u32, s.message.clone()));
        }
    }
    Ok(())
}

fn echo_metadata(ctx: &CallCtx) {
    if let Some(v) = ctx.metadata.get("x-grpc-test-echo-initial") {
        let mut md = Metadata::new();
        md.insert("x-grpc-test-echo-initial".into(), v.clone());
        ctx.set_headers(md);
    }
    if let Some(v) = ctx.metadata.get("x-grpc-test-echo-trailing-bin") {
        let mut md = Metadata::new();
        md.insert("x-grpc-test-echo-trailing-bin".into(), v.clone());
        ctx.set_trailers(md);
    }
}

fn set_orca_trailer(ctx: &CallCtx, report: &pb::OrcaLoadReport) {
    let mut md = Metadata::new();
    md.insert(
        "endpoint-load-metrics-bin".into(),
        pb::base64_encode(&pb::OrcaLoadReport::encode(report)),
    );
    ctx.set_trailers(md);
}

/// Compression interop (server direction): the proxy surfaces
/// the declared encoding as metadata; expect_compressed fails
/// without it, response_compressed declares gzip back.
fn compression_checks(
    ctx: &CallCtx,
    expect: &Option<Box<pb::BoolValue>>,
    response_compressed: &Option<Box<pb::BoolValue>>,
) -> Result<(), Status> {
    if expect.as_ref().is_some_and(|b| b.value)
        && ctx.metadata.get("grpc-encoding").map(String::as_str) != Some("gzip")
    {
        return Err(Status::invalid_argument(
            "expected compressed request, got uncompressed",
        ));
    }
    if response_compressed.as_ref().is_some_and(|b| b.value) {
        let mut md = Metadata::new();
        md.insert("grpc-encoding".into(), "gzip".into());
        ctx.set_headers(md);
    }
    Ok(())
}

fn unary_response(req: &pb::SimpleRequest) -> Result<pb::SimpleResponse, Status> {
    maybe_fail(&req.response_status)?;
    Ok(pb::SimpleResponse {
        payload: Some(Box::new(pb::Payload {
            r#type: req.response_type,
            body: vec![0u8; req.response_size.max(0) as usize],
            ..Default::default()
        })),
        ..Default::default()
    })
}

fn response_stream(
    req: &pb::StreamingOutputCallRequest,
) -> Pin<Box<dyn Stream<Item = Result<pb::StreamingOutputCallResponse, Status>> + Send>> {
    let responses: Vec<_> = req
        .response_parameters
        .iter()
        .map(|p| pb::StreamingOutputCallResponse {
            payload: Some(Box::new(pb::Payload {
                r#type: req.response_type,
                body: vec![0u8; p.size.max(0) as usize],
                ..Default::default()
            })),
            ..Default::default()
        })
        .collect();
    Box::pin(futures_util::stream::iter(responses.into_iter().map(Ok)))
}

struct TestServiceImpl {
    oob: Arc<Mutex<Option<pb::OrcaLoadReport>>>,
}

#[async_trait]
impl test_stub::TestService for TestServiceImpl {
    async fn empty_call(&self, _req: pb::Empty, ctx: CallCtx) -> Result<pb::Empty, Status> {
        echo_metadata(&ctx);
        Ok(pb::Empty::default())
    }

    async fn unary_call(
        &self,
        req: pb::SimpleRequest,
        ctx: CallCtx,
    ) -> Result<pb::SimpleResponse, Status> {
        echo_metadata(&ctx);
        compression_checks(&ctx, &req.expect_compressed, &req.response_compressed)?;
        if let Some(r) = &req.orca_per_query_report {
            set_orca_trailer(
                &ctx,
                &pb::OrcaLoadReport {
                    cpu_utilization: r.cpu_utilization,
                    mem_utilization: r.memory_utilization,
                    request_cost: r.request_cost.clone(),
                    utilization: r.utilization.clone(),
                    ..Default::default()
                },
            );
        } else if let Some(report) = self.oob.lock().unwrap().clone() {
            set_orca_trailer(&ctx, &report);
        }
        unary_response(&req)
    }

    async fn cacheable_unary_call(
        &self,
        req: pb::SimpleRequest,
        ctx: CallCtx,
    ) -> Result<pb::SimpleResponse, Status> {
        echo_metadata(&ctx);
        maybe_fail(&req.response_status)?;
        Ok(pb::SimpleResponse {
            payload: req.payload.clone(),
            ..Default::default()
        })
    }

    async fn streaming_output_call(
        &self,
        req: pb::StreamingOutputCallRequest,
        ctx: CallCtx,
    ) -> Result<ResponseStream<pb::StreamingOutputCallResponse>, Status> {
        echo_metadata(&ctx);
        maybe_fail(&req.response_status)?;
        Ok(response_stream(&req))
    }

    async fn streaming_input_call(
        &self,
        reqs: RequestStream<pb::StreamingInputCallRequest>,
        ctx: CallCtx,
    ) -> Result<pb::StreamingInputCallResponse, Status> {
        echo_metadata(&ctx);
        let mut total: i32 = 0;
        let mut reqs = reqs;
        while let Some(req) = reqs.try_next().await? {
            if req.expect_compressed.as_ref().is_some_and(|b| b.value)
                && ctx.metadata.get("grpc-encoding").map(String::as_str) != Some("gzip")
            {
                return Err(Status::invalid_argument(
                    "expected compressed request, got uncompressed",
                ));
            }
            if let Some(p) = &req.payload {
                total += p.body.len() as i32;
            }
        }
        Ok(pb::StreamingInputCallResponse {
            aggregated_payload_size: total,
            ..Default::default()
        })
    }

    async fn full_duplex_call(
        &self,
        reqs: RequestStream<pb::StreamingOutputCallRequest>,
        ctx: CallCtx,
    ) -> Result<ResponseStream<pb::StreamingOutputCallResponse>, Status> {
        echo_metadata(&ctx);
        let oob = self.oob.clone();
        let stream = futures_util::stream::unfold(
            (reqs, std::collections::VecDeque::new(), false),
            move |(mut reqs, mut pending, mut done)| {
                let oob = oob.clone();
                async move {
                    loop {
                        if let Some(item) = pending.pop_front() {
                            return Some((item, (reqs, pending, done)));
                        }
                        if done {
                            return None;
                        }
                        match reqs.next().await {
                            Some(Ok(req)) => {
                                if let Some(r) = &req.orca_oob_report {
                                    *oob.lock().unwrap() = Some(pb::OrcaLoadReport {
                                        cpu_utilization: r.cpu_utilization,
                                        mem_utilization: r.memory_utilization,
                                        utilization: r.utilization.clone(),
                                        ..Default::default()
                                    });
                                }
                                match maybe_fail(&req.response_status) {
                                    Ok(()) => {
                                        let responses: Vec<_> =
                                            response_stream(&req).collect().await;
                                        pending.extend(responses);
                                    }
                                    Err(s) => return Some((Err(s), (reqs, pending, true))),
                                }
                            }
                            Some(Err(s)) => return Some((Err(s), (reqs, pending, true))),
                            None => return None,
                        }
                    }
                }
            },
        );
        Ok(Box::pin(stream))
    }

    async fn half_duplex_call(
        &self,
        reqs: RequestStream<pb::StreamingOutputCallRequest>,
        ctx: CallCtx,
    ) -> Result<ResponseStream<pb::StreamingOutputCallResponse>, Status> {
        echo_metadata(&ctx);
        let reqs: Vec<_> = reqs.try_collect().await?;
        let mut out = Vec::new();
        for req in &reqs {
            maybe_fail(&req.response_status)?;
            out.extend(req.response_parameters.iter().map(|p| pb::StreamingOutputCallResponse {
                payload: Some(Box::new(pb::Payload {
                    r#type: req.response_type,
                    body: vec![0u8; p.size.max(0) as usize],
                    ..Default::default()
                })),
                ..Default::default()
            }));
        }
        Ok(Box::pin(futures_util::stream::iter(out.into_iter().map(Ok))))
    }

    async fn unimplemented_call(
        &self,
        _req: pb::Empty,
        _ctx: CallCtx,
    ) -> Result<pb::Empty, Status> {
        Err(Status::unimplemented("not implemented"))
    }
}

struct OpenRcaServiceImpl {
    oob: Arc<Mutex<Option<pb::OrcaLoadReport>>>,
}

#[async_trait]
impl orca_stub::OpenRcaService for OpenRcaServiceImpl {
    async fn stream_core_metrics(
        &self,
        _req: pb::OrcaLoadReportRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::OrcaLoadReport>, Status> {
        let oob = self.oob.clone();
        let stream = futures_util::stream::unfold((), move |()| {
            let oob = oob.clone();
            async move {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                let report = oob.lock().unwrap().clone().unwrap_or_default();
                Some((Ok(report), ()))
            }
        });
        Ok(Box::pin(stream))
    }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    let oob = Arc::new(Mutex::new(None));
    let transport: Arc<dyn DcTransport> = Arc::new(StdioDc {
        tx: tokio::sync::Mutex::new(tokio::io::stdout()),
        rx: tokio::sync::Mutex::new(tokio::io::stdin()),
    });
    Server::serve(
        transport,
        vec![
            test_stub::test_service_service(Arc::new(TestServiceImpl { oob: oob.clone() })),
            orca_stub::open_rca_service_service(Arc::new(OpenRcaServiceImpl { oob })),
        ],
    )
    .await;
}
