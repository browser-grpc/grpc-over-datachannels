//! Kafka protocol client library.
//!
//! The dependency-free Kafka wire implementation (Apache Kafka
//! and Redpanda) that powers the `kafka_proxy` sidecar, packaged
//! as a library: embed it in-process (`Broker` for the raw
//! protocol operations, `KafkaService` for the full
//! `grpcdc.kafka.v1` service semantics with producer sessions
//! and consumer groups), or link it from another language
//! through the C ABI in `ffi` (cdylib).
//!
//! The generated message/stub types are the same ones the proxy
//! and the per-language clients use, so an embedded client and
//! a sidecar client are wire-identical.

#[path = "../../../rust/gen/kafka_pb.rs"]
pub mod pb;

mod pb_message_impl;

#[path = "../../../rust/gen/kafka_grpc_dc.rs"]
pub mod stub;

pub mod client;
pub mod codecs;
pub mod crypto;
pub mod ffi;
pub mod service;
pub mod wire;

pub use client::{Broker, KafkaConfig, SaslConfig, TlsConfig};
pub use service::KafkaService;
