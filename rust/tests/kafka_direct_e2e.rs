//! Direct in-process use of the `kafka-native` library: no
//! gRPC, no proxy process, no transport. The same `Broker`
//! and `KafkaService` the sidecar hosts are called as a
//! library — the native collapsed form factor.
//!
//! Set KAFKA_PROXY_E2E_BROKER=host:port to run (Apache Kafka
//! or Redpanda). Without it the test is a no-op so plain
//! `cargo test` stays green on machines without a broker.

use futures_util::StreamExt;
use kafka_native::client::KafkaConfig;
use kafka_native::stub::Kafka;
use kafka_native::{pb, Broker, KafkaService};
use std::sync::Arc;

fn broker_or_skip() -> Option<String> {
    match std::env::var("KAFKA_PROXY_E2E_BROKER") {
        Ok(b) => Some(b),
        Err(_) => {
            eprintln!("KAFKA_PROXY_E2E_BROKER unset: skipping");
            None
        }
    }
}

fn unique_topic(prefix: &str) -> String {
    format!(
        "{prefix}-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    )
}

fn record(value: &str) -> pb::Record {
    pb::Record { value: value.as_bytes().to_vec(), ..Default::default() }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_direct_broker_roundtrip() {
    let Some(broker_addr) = broker_or_skip() else { return };
    let broker = Broker::new(KafkaConfig {
        broker: broker_addr,
        client_id: "grpc-dc-kafka-direct-e2e".to_string(),
        sasl: None,
        tls: None,
    });
    let topic = unique_topic("grpc-dc-direct");
    let created = broker
        .create_topics(vec![(topic.clone(), 1, 1)], 30_000, false)
        .await
        .expect("create topic");
    assert_eq!(created[0].1, 0, "create failed: {created:?}");

    // Wait for leader election via metadata.
    for _ in 0..50 {
        let meta = broker.metadata(vec![topic.clone()], false).await.expect("metadata");
        let ready = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .map(|t| t.partitions.iter().any(|p| p.leader_id >= 0))
            .unwrap_or(false);
        if ready {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    let produced = broker
        .produce(&topic, 0, &[record("one"), record("two"), record("three")], -1, 30_000, 0, -1, -1, -1, None)
        .await
        .expect("produce");
    assert_eq!(produced.error_code, 0, "produce failed, error_code={}", produced.error_code);
    assert_eq!(produced.base_offset, 0);

    let (earliest, _, err) = broker.list_offsets(&topic, 0, -2, false).await.expect("list offsets");
    assert_eq!(err, 0);
    assert_eq!(earliest, 0);

    let fetched = broker
        .fetch(&topic, 0, 0, 2_000, 1, 4 * 1024 * 1024, false)
        .await
        .expect("fetch");
    assert_eq!(fetched.error_code, 0, "fetch failed, error_code={}", fetched.error_code);
    let values: Vec<String> = fetched
        .records
        .iter()
        .map(|r| String::from_utf8(r.value.clone()).expect("utf8"))
        .collect();
    assert_eq!(values, vec!["one", "two", "three"]);
    assert_eq!(fetched.high_watermark, 3);

    let deleted = broker.delete_topics(vec![topic.clone()], 30_000).await.expect("delete topics");
    assert_eq!(deleted[0].1, 0, "delete failed: {deleted:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_direct_admin() {
    let Some(broker_addr) = broker_or_skip() else { return };
    let broker = Broker::new(KafkaConfig {
        broker: broker_addr,
        client_id: "grpc-dc-kafka-direct-admin-e2e".to_string(),
        sasl: None,
        tls: None,
    });
    let topic = unique_topic("grpc-dc-direct-admin");
    let created = broker
        .create_topics(vec![(topic.clone(), 1, 1)], 30_000, false)
        .await
        .expect("create topic");
    assert_eq!(created[0].1, 0, "create failed: {created:?}");

    // CreatePartitions 1 -> 3, verified through metadata.
    let err = broker.create_partitions(&topic, 3, false, 30_000).await.expect("create partitions");
    assert_eq!(err, 0, "create partitions error {err}");
    let mut partitions = 0;
    for _ in 0..50 {
        let meta = broker.metadata(vec![topic.clone()], false).await.expect("metadata");
        partitions = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .map(|t| t.partitions.len())
            .unwrap_or(0);
        if partitions == 3 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    assert_eq!(partitions, 3);

    // AlterConfigs then DescribeConfigs until the value is
    // visible (config propagation is eventually consistent).
    // Resource type 2 = TOPIC (Kafka wire code), op 0 = SET.
    let err = broker
        .alter_configs(
            2,
            &topic,
            &[("max.message.bytes".to_string(), "12345".to_string(), 0)],
            false,
        )
        .await
        .expect("alter configs");
    assert_eq!(err, 0, "alter configs error {err}");
    let mut visible = String::new();
    for _ in 0..50 {
        let (err, values) = broker
            .describe_configs(2, &topic, &["max.message.bytes".to_string()], false)
            .await
            .expect("describe configs");
        assert_eq!(err, 0, "describe configs error {err}");
        visible = values
            .iter()
            .find(|v| v.name == "max.message.bytes")
            .map(|v| v.value.clone())
            .unwrap_or_default();
        if visible == "12345" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    assert_eq!(visible, "12345");

    // ListGroups runs against the live broker (no members
    // needed for the call itself).
    let (err, _groups) = broker.list_groups().await.expect("list groups");
    assert_eq!(err, 0, "list groups error {err}");

    let deleted = broker.delete_topics(vec![topic.clone()], 30_000).await.expect("delete topics");
    assert_eq!(deleted[0].1, 0, "delete failed: {deleted:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_direct_service_in_process() {
    let Some(broker_addr) = broker_or_skip() else { return };
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: broker_addr,
        client_id: "grpc-dc-kafka-direct-svc-e2e".to_string(),
        sasl: None,
        tls: None,
    }));
    let topic = unique_topic("grpc-dc-direct-svc");
    let created = Kafka::create_topics(
        &*service,
        pb::CreateTopicsRequest {
            topics: vec![pb::NewTopic {
                name: topic.clone(),
                num_partitions: 1,
                replication_factor: 1,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        },
        grpc_dc::CallCtx::detached("/grpcdc.kafka.v1.Kafka/CreateTopics"),
    )
    .await
    .expect("service create topics");
    assert_eq!(created.results[0].error_code, 0, "create failed: {created:?}");

    let produced = Kafka::produce(
        &*service,
        pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("alpha"), record("beta")],
            acks: pb::Acks::AcksAll,
            ..Default::default()
        },
        grpc_dc::CallCtx::detached("/grpcdc.kafka.v1.Kafka/Produce"),
    )
    .await
    .expect("service produce");
    assert_eq!(produced.error_code, 0, "produce failed, error_code={}", produced.error_code);

    let mut stream = Kafka::consume(
        &*service,
        pb::ConsumeRequest {
            topic: topic.clone(),
            partition: 0,
            offset: -2,
            max_records: 10,
            max_wait_ms: 2_000,
            ..Default::default()
        },
        grpc_dc::CallCtx::detached("/grpcdc.kafka.v1.Kafka/Consume"),
    )
    .await
    .expect("service consume");
    let mut values = Vec::new();
    while values.len() < 2 {
        let chunk = stream
            .next()
            .await
            .expect("consume stream ended early")
            .expect("consume chunk");
        assert_eq!(chunk.error_code, 0, "consume error: {chunk:?}");
        for rec in chunk.records {
            values.push(String::from_utf8(rec.value).expect("utf8"));
        }
    }
    assert_eq!(values, vec!["alpha", "beta"]);
}
