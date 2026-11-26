//! gRPC service layer over the kafka-native protocol client.
//!
//! `KafkaService` maps the generated `grpcdc.kafka.v1` service
//! onto `kafka_native::Broker`; `StreamsService` does the same
//! for the Kafka Streams topologies; the C ABI in `ffi`
//! (cdylib, staged as `libkafka_native`) dispatches the same
//! service in-process for per-language FFI wrappers.
//!
//! The direct protocol client lives in the `kafka-native`
//! crate; this crate is the server/binding side and is what
//! the kafka_proxy executable hosts.

pub use kafka_native::pb;

mod pb_message_impl;

#[path = "../../../rust/gen/kafka_grpc_dc.rs"]
pub mod stub;

#[path = "../../../rust/gen/kafka_streams_pb.rs"]
pub mod streams_pb;

#[path = "../../../rust/gen/kafka_streams_processor_pb.rs"]
pub mod processor_pb;

pub mod ffi;
pub mod service;
pub mod streams;

pub use service::KafkaService;
pub use streams::{processor_context_service, streams_service, StreamsService};
