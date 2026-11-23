//! Struct codec corpus: roundtrip and protobuf<->struct
//! transcode stability on the generated interop messages, plus
//! corrupt-input safety. The layout is byte-identical to the Go
//! struct codec (template-go.rkt / template-rust.rkt v1).

#[path = "../gen/messages_pb.rs"]
mod messages_pb;

use messages_pb::{Payload, PayloadType, SimpleRequest};

fn sample() -> SimpleRequest {
    SimpleRequest {
        response_type: PayloadType::Compressable,
        response_size: 1024,
        payload: Some(Box::new(Payload {
            r#type: PayloadType::Compressable,
            body: vec![0xAB; 4096],
            unknown_fields: Vec::new(),
        })),
        fill_username: true,
        fill_server_id: true,
        ..Default::default()
    }
}

#[test]
fn struct_roundtrip_and_transcode() {
    let req = sample();
    let bytes = req.marshal_struct();
    assert_eq!(&bytes[0..4], b"DCS1");
    let back = SimpleRequest::unmarshal_struct(&bytes).unwrap();
    assert_eq!(back.response_size, 1024);
    assert_eq!(back.payload.as_ref().unwrap().body.len(), 4096);
    // struct -> protobuf -> struct must be byte-stable.
    let from_pb = SimpleRequest::decode(&back.encode()).unwrap();
    assert_eq!(bytes, from_pb.marshal_struct());
    // Truncated input errors instead of panicking.
    assert!(SimpleRequest::unmarshal_struct(&bytes[..5]).is_err());
    // Wrong schema fingerprint errors.
    let mut bad = bytes.clone();
    bad[8] ^= 0xFF;
    assert!(SimpleRequest::unmarshal_struct(&bad).is_err());
}
