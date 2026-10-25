//! BDD: interprets the generated behavior scenarios
//! (`bdd_scenarios/mod.rs`, generated from `the BDD specification`;
//! prose in BDD.md) against a loopback client+server — the
//! executable examples.

#[path = "../gen/echo_pb.rs"]
mod pb;

#[path = "../examples/echo_demo/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/echo_grpc_dc.rs"]
mod stub;

mod bdd_scenarios;

use futures_util::{StreamExt, TryStreamExt};
use grpc_dc::{
    loopback_pair, CallCtx, Channel, DcTransport, Metadata, RequestStream, ResponseStream,
    Server, Status,
};
use std::sync::Arc;
use stub::{echo_service, Echo, EchoClient};

struct EchoService;

#[grpc_dc::async_trait]
impl Echo for EchoService {
    async fn unary(&self, req: pb::EchoRequest, ctx: CallCtx) -> Result<pb::EchoResponse, Status> {
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        if req.delay_ms > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(req.delay_ms as u64)).await;
        }
        let suffix = ctx
            .metadata
            .get("x-echo")
            .map(|v| format!(" [{v}]"))
            .unwrap_or_default();
        if let Some(v) = ctx.metadata.get("x-echo-trailer") {
            let mut t = Metadata::new();
            t.insert("x-echo-trailer".to_string(), v.clone());
            ctx.set_trailers(t);
        }
        Ok(pb::EchoResponse { message: format!("echo: {}{}", req.message, suffix), index: 0 , ..Default::default() })
    }

    async fn server_stream(
        &self,
        req: pb::EchoRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        if req.message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let responses =
            (0..req.count.max(0)).map(move |i| Ok(pb::EchoResponse { message: req.message.clone(), index: i , ..Default::default() }));
        Ok(Box::pin(futures_util::stream::iter(responses)))
    }

    async fn client_stream(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<pb::EchoResponse, Status> {
        let parts: Vec<String> = reqs.map_ok(|r| r.message).try_collect().await?;
        Ok(pb::EchoResponse { message: parts.join("+"), index: parts.len() as i32 , ..Default::default() })
    }

    async fn bidi(
        &self,
        reqs: RequestStream<pb::EchoRequest>,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<pb::EchoResponse>, Status> {
        let stream = futures_util::stream::unfold((reqs, 0i32), |(mut reqs, mut index)| async move {
            match reqs.next().await {
                Some(Ok(req)) if req.message == "fail" => {
                    Some((Err(Status::invalid_argument("asked to fail")), (reqs, index)))
                }
                Some(Ok(req)) => {
                    let resp = pb::EchoResponse { message: req.message, index , ..Default::default() };
                    index += 1;
                    Some((Ok(resp), (reqs, index)))
                }
                Some(Err(e)) => Some((Err(e), (reqs, index))),
                None => None,
            }
        });
        Ok(Box::pin(stream))
    }
}

fn req(message: &str, count: i32) -> pb::EchoRequest {
    pb::EchoRequest { message: message.into(), count, delay_ms: 0, ..Default::default() }
}

async fn setup() -> (Channel, EchoClient) {
    let (a, b) = loopback_pair();
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![echo_service(Arc::new(EchoService))]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let channel = Channel::new(client_transport);
    let client = EchoClient::new(channel.clone());
    (channel, client)
}

#[tokio::test]
async fn bdd_scenarios() {
    let (channel, client) = setup().await;
    for c in bdd_scenarios::BDD_SCENARIOS {
        let line = format!("bdd {} ({})", c.name, c.kind);
        match c.kind {
            "unary-trailer" => {
                let trailers = Arc::new(std::sync::Mutex::new(Metadata::new()));
                let mut md = Metadata::new();
                md.insert("x-echo-trailer".to_string(), c.metadata.to_string());
                let options = grpc_dc::CallOptions::new()
                    .metadata(md)
                    .capture_trailers(trailers.clone());
                let resp = client
                    .unary_with_options(req(c.messages[0], 0), options)
                    .await
                    .unwrap();
                assert_eq!(resp.message, c.expect_message, "{line}");
                assert_eq!(resp.index, c.expect_num, "{line}");
                assert_eq!(
                    trailers.lock().unwrap().get("x-echo-trailer").map(|v| v.as_str()),
                    Some(c.metadata),
                    "{line}"
                );
            }
            "unary" => {
                let result = if c.metadata.is_empty() {
                    client.unary(req(c.messages[0], 0)).await
                } else {
                    let mut md: std::collections::HashMap<String, String> = Default::default();
                    md.insert("x-echo".to_string(), c.metadata.to_string());
                    channel
                        .unary_with("/echo.Echo/Unary", req(c.messages[0], 0), md)
                        .await
                };
                match result {
                    Ok(resp) => {
                        assert!(c.expect_status.is_none(), "{line}: expected failure, got {resp:?}");
                        assert_eq!(resp.message, c.expect_message, "{line}");
                        assert_eq!(resp.index, c.expect_num, "{line}");
                    }
                    Err(status) => {
                        assert_eq!(c.expect_status, Some(status.code as u32), "{line}: {status}");
                    }
                }
            }
            "server-stream" => {
                let mut stream = client.server_stream(req(c.messages[0], c.count)).await.unwrap();
                let mut got: Vec<pb::EchoResponse> = Vec::new();
                while let Some(item) = stream.next().await {
                    got.push(item.unwrap());
                }
                assert_eq!(got.len() as i32, c.expect_num, "{line}");
                for (i, resp) in got.iter().enumerate() {
                    assert_eq!(resp.message, c.expect_message, "{line}");
                    assert_eq!(resp.index, i as i32, "{line}");
                }
            }
            "client-stream" => {
                let reqs = futures_util::stream::iter(c.messages.iter().map(|m| req(m, 0)));
                let resp = client.client_stream(reqs).await.unwrap();
                assert_eq!(resp.message, c.expect_message, "{line}");
                assert_eq!(resp.index, c.expect_num, "{line}");
            }
            "bidi" => {
                let reqs = futures_util::stream::iter(c.messages.iter().map(|m| req(m, 0)));
                let mut stream = client.bidi(reqs).await.unwrap();
                let mut got: Vec<pb::EchoResponse> = Vec::new();
                while let Some(item) = stream.next().await {
                    got.push(item.unwrap());
                }
                assert_eq!(got.len() as i32, c.expect_num, "{line}");
                for (i, resp) in got.iter().enumerate() {
                    assert_eq!(resp.message, c.messages[i], "{line}");
                    assert_eq!(resp.index, i as i32, "{line}");
                }
            }
            "server-stream-fail" => {
                let mut stream = client.server_stream(req(c.messages[0], c.count)).await.unwrap();
                let mut result = Ok(());
                while let Some(item) = stream.next().await {
                    if let Err(e) = item {
                        result = Err(e);
                        break;
                    }
                }
                let status = result.expect_err(&line);
                assert_eq!(c.expect_status, Some(status.code as u32), "{line}: {status}");
            }
            "bidi-fail" => {
                let reqs = futures_util::stream::iter(c.messages.iter().map(|m| req(m, 0)));
                let mut stream = client.bidi(reqs).await.unwrap();
                let mut result = Ok(());
                while let Some(item) = stream.next().await {
                    if let Err(e) = item {
                        result = Err(e);
                        break;
                    }
                }
                let status = result.expect_err(&line);
                assert_eq!(c.expect_status, Some(status.code as u32), "{line}: {status}");
            }
            "deadline" => {
                let delayed = pb::EchoRequest {
                    message: c.messages[0].into(),
                    count: 0,
                    delay_ms: c.count,
                    ..Default::default()
                };
                let result = client
                    .unary_with_options(
                        delayed,
                        grpc_dc::CallOptions::with_timeout(std::time::Duration::from_millis(100)),
                    )
                    .await;
                let status = result.expect_err(&line);
                assert_eq!(c.expect_status, Some(status.code as u32), "{line}: {status}");
            }
            "cancel" => {
                let mut stream = client.server_stream(req(c.messages[0], c.count)).await.unwrap();
                let first = stream.next().await.expect("first response").unwrap();
                assert_eq!(first.message, c.messages[0], "{line}");
                drop(stream);
                // Dropping the stream aborts the call; reaching
                // here with the runtime still live is the
                // assertion (a hang would fail by timeout).
            }
            "raw-unary" => {
                let result: Result<pb::EchoResponse, Status> =
                    channel.unary(c.path, req(c.messages[0], 0)).await;
                match result {
                    Ok(resp) => panic!("{line}: expected failure, got {resp:?}"),
                    Err(status) => {
                        assert_eq!(c.expect_status, Some(status.code as u32), "{line}: {status}");
                    }
                }
            }
            _ => panic!("unknown bdd kind: {}", c.kind),
        }
    }
}
