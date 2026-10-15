//! Dynamic Echo implementation: the reference Echo semantics built
//! purely on the descriptor-driven runtime (no generated stubs).
//! Field numbers come from proto/echo.proto: EchoRequest{message=1,
//! count=2}, EchoResponse{message=1, index=2}.

use futures_util::StreamExt;
use grpc_dc::dynamic::{
    DynamicHandler, DynamicRequestStream, DynamicSink, GenericMessage, MethodModel,
};
use grpc_dc::{CallCtx, Status};

fn response(_method: &MethodModel, message: String, index: i64) -> GenericMessage {
    let mut resp = GenericMessage::new();
    resp.set(1, message);
    resp.set(2, index);
    resp
}

/// Handler protocol for grpc_dc::dynamic_service.
pub struct DynamicEchoService;

#[grpc_dc::async_trait]
impl DynamicHandler for DynamicEchoService {
    async fn unary(
        &self,
        ctx: CallCtx,
        method: &MethodModel,
        request: GenericMessage,
    ) -> Result<GenericMessage, Status> {
        let message = request.get_string(1);
        if message == "fail" {
            return Err(Status::invalid_argument("asked to fail"));
        }
        let suffix = ctx
            .metadata
            .get("x-echo")
            .map(|v| format!(" [{v}]"))
            .unwrap_or_default();
        Ok(response(method, format!("echo: {message}{suffix}"), 0))
    }

    async fn server_stream(
        &self,
        _ctx: CallCtx,
        method: &MethodModel,
        request: GenericMessage,
        sink: DynamicSink,
    ) -> Result<(), Status> {
        let count = request.get_i64(2).max(0);
        for i in 0..count {
            sink.send(&response(method, request.get_string(1), i)).await?;
        }
        Ok(())
    }

    async fn client_stream(
        &self,
        _ctx: CallCtx,
        method: &MethodModel,
        mut requests: DynamicRequestStream,
    ) -> Result<GenericMessage, Status> {
        let mut parts: Vec<String> = Vec::new();
        while let Some(req) = requests.next().await {
            parts.push(req?.get_string(1));
        }
        let total = parts.len() as i64;
        Ok(response(method, parts.join("+"), total))
    }

    async fn bidi(
        &self,
        _ctx: CallCtx,
        method: &MethodModel,
        mut requests: DynamicRequestStream,
        sink: DynamicSink,
    ) -> Result<(), Status> {
        let mut index: i64 = 0;
        while let Some(req) = requests.next().await {
            let req = req?;
            sink.send(&response(method, req.get_string(1), index)).await?;
            index += 1;
        }
        Ok(())
    }
}
