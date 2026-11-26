//! Kafka protocol client library.
//!
//! The dependency-free Kafka wire implementation (Apache Kafka
//! and Redpanda): embed it in-process (`Broker` for the raw
//! protocol operations) and speak the Kafka binary protocol
//! directly to the broker — no proxy, no gRPC hop.
//!
//! The gRPC service layer over this client (`KafkaService`,
//! `StreamsService`, and the C ABI staged as `libkafka_native`)
//! lives in the `kafka-service` crate; the kafka_proxy
//! executable hosts it. The generated message types are the
//! same ones the proxy and the per-language clients use, so an
//! embedded client and a sidecar client are wire-identical.

#[path = "../../../rust/gen/kafka_pb.rs"]
pub mod pb;

mod pb_message_impl;

pub mod client;
pub mod codecs;
pub mod crypto;
pub mod wire;

pub use client::{Broker, KafkaConfig, SaslConfig, TlsConfig};
