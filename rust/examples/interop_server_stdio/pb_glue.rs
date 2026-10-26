//! Generated-message glue for the Rust interop harness: the
//! vendored grpc.testing / ORCA message modules (generated into
//! rust/gen by `make interop-stubs`) re-exported as one `pb`
//! module, plus their `grpc_dc::Message` adapters. Included as
//! `mod pb` by the interop server example and the interop
//! oracle test; not part of the runtime.

#[path = "../../gen/empty_pb.rs"]
mod empty_pb;
#[path = "../../gen/messages_pb.rs"]
mod messages_pb;
#[path = "../../gen/orca_load_report_pb.rs"]
mod orca_load_report_pb;
#[path = "../../gen/orca_pb.rs"]
mod orca_pb;

pub use empty_pb::*;
pub use messages_pb::*;
pub use orca_load_report_pb::*;
pub use orca_pb::*;

macro_rules! interop_message {
    ($t:ty) => {
        impl ::grpc_dc::Message for $t {
            fn encode(&self) -> Vec<u8> {
                <$t>::encode(self)
            }

            fn decode(bytes: &[u8]) -> Result<Self, ::grpc_dc::Status> {
                <$t>::decode(bytes).map_err(::grpc_dc::Status::invalid_argument)
            }
        }
    };
}

interop_message!(Empty);
interop_message!(SimpleRequest);
interop_message!(SimpleResponse);
interop_message!(StreamingInputCallRequest);
interop_message!(StreamingInputCallResponse);
interop_message!(StreamingOutputCallRequest);
interop_message!(StreamingOutputCallResponse);
interop_message!(OrcaLoadReport);
interop_message!(OrcaLoadReportRequest);
// The remaining grpc.testing services in test.proto (not
// exercised by the harness, but their generated stubs need
// Message impls to compile).
interop_message!(ReconnectParams);
interop_message!(ReconnectInfo);
interop_message!(LoadBalancerStatsRequest);
interop_message!(LoadBalancerStatsResponse);
interop_message!(LoadBalancerAccumulatedStatsRequest);
interop_message!(LoadBalancerAccumulatedStatsResponse);
interop_message!(ClientConfigureRequest);
interop_message!(ClientConfigureResponse);

/// Minimal base64 (standard alphabet, padded) for the
/// `endpoint-load-metrics-bin` trailer, whose value is base64
/// on the wire exactly as in gRPC HTTP/2. Test-harness code;
/// the runtime itself never interprets -bin values.
pub fn base64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[n as usize & 63] as char } else { '=' });
    }
    out
}

pub fn base64_decode(text: &str) -> Result<Vec<u8>, String> {
    fn value(c: u8) -> Result<u32, String> {
        match c {
            b'A'..=b'Z' => Ok((c - b'A') as u32),
            b'a'..=b'z' => Ok((c - b'a') as u32 + 26),
            b'0'..=b'9' => Ok((c - b'0') as u32 + 52),
            b'+' => Ok(62),
            b'/' => Ok(63),
            _ => Err(format!("invalid base64 byte {c}")),
        }
    }
    let bytes: Vec<u8> = text.bytes().filter(|c| *c != b'=').collect();
    let mut out = Vec::new();
    for chunk in bytes.chunks(4) {
        let mut n: u32 = 0;
        for (i, c) in chunk.iter().enumerate() {
            n |= value(*c)? << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    Ok(out)
}
