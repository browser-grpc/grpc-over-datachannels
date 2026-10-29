//! End-to-end smoke test for the Rust Kafka proxy: a
//! generated gRPC client talks over a loopback DataChannel to
//! the generated Kafka service, which speaks the Kafka
//! protocol to a real broker.
//!
//! Set KAFKA_PROXY_E2E_BROKER=host:port to run (Apache Kafka
//! or Redpanda). Without it the test is a no-op so plain
//! `cargo test` stays green on machines without a broker.

#[path = "../gen/kafka_pb.rs"]
mod pb;

#[path = "../examples/kafka_proxy/pb_message_impl.rs"]
mod pb_message_impl;

#[path = "../gen/kafka_grpc_dc.rs"]
mod stub;

#[path = "../examples/kafka_proxy/wire.rs"]
mod wire;

#[path = "../examples/kafka_proxy/codecs.rs"]
mod codecs;

#[path = "../examples/kafka_proxy/crypto.rs"]
mod crypto;

#[path = "../examples/kafka_proxy/client.rs"]
mod client;

#[path = "../examples/kafka_proxy/service.rs"]
mod service;

use client::KafkaConfig;
use futures_util::StreamExt;
use grpc_dc::{loopback_pair, Channel, DcTransport, Server};
use service::KafkaService;
use std::sync::Arc;
use stub::{kafka_service, KafkaClient};

async fn setup(broker: &str) -> KafkaClient {
    let (a, b) = loopback_pair();
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: broker.to_string(),
        client_id: "grpc-dc-kafka-proxy-e2e".to_string(),
        sasl: None,
        tls: None,
    }));
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![kafka_service(service)]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    KafkaClient::new(Channel::new(client_transport))
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

async fn make_topic(client: &KafkaClient, topic: &str, partitions: i32) {
    let created = client
        .create_topics(pb::CreateTopicsRequest {
            topics: vec![pb::NewTopic {
                name: topic.to_string(),
                num_partitions: partitions,
                replication_factor: 1,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("create topic rpc");
    assert_eq!(created.results[0].error_code, 0, "create failed: {created:?}");
    for _ in 0..50 {
        let meta = client
            .metadata(pb::MetadataRequest { topics: vec![topic.to_string()], ..Default::default() })
            .await
            .expect("metadata rpc");
        let visible = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .map(|t| t.partitions.len())
            .unwrap_or(0);
        if visible == partitions as usize {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    panic!("topic {topic} never became visible");
}

async fn produce_one(client: &KafkaClient, topic: &str, value: &str) -> pb::ProduceResponse {
    client
        .produce(pb::ProduceRequest {
            topic: topic.to_string(),
            partition: 0,
            records: vec![record(value)],
            acks: pb::Acks::AcksAll,
            ..Default::default()
        })
        .await
        .expect("produce rpc")
}

async fn consume_values(client: &KafkaClient, topic: &str, want: usize) -> Vec<String> {
    consume_values_mode(client, topic, want, false).await
}

async fn consume_values_mode(
    client: &KafkaClient,
    topic: &str,
    want: usize,
    read_committed: bool,
) -> Vec<String> {
    let mut stream = client
        .consume(pb::ConsumeRequest {
            topic: topic.to_string(),
            partition: 0,
            offset: -2,
            max_records: 100,
            max_wait_ms: 2_000,
            read_committed,
            ..Default::default()
        })
        .await
        .expect("consume rpc");
    let mut values = Vec::new();
    let collect = async {
        while values.len() < want {
            match stream.next().await {
                Some(Ok(chunk)) => {
                    assert_eq!(chunk.error_code, 0, "consume error: {chunk:?}");
                    for rec in chunk.records {
                        values.push(String::from_utf8(rec.value).expect("utf8"));
                    }
                }
                Some(Err(e)) => panic!("consume stream error: {e:?}"),
                None => break,
            }
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(30), collect)
        .await
        .expect("consume timed out");
    values
}

/// Drain whatever a read_committed consume returns within a
/// short window; used to assert uncommitted/aborted records are
/// invisible (an open-ended "wait for 1" would hang when the
/// broker is behaving correctly).
async fn drain_committed_window(client: &KafkaClient, topic: &str) -> Vec<String> {
    let mut stream = client
        .consume(pb::ConsumeRequest {
            topic: topic.to_string(),
            partition: 0,
            offset: -2,
            max_records: 100,
            max_wait_ms: 500,
            read_committed: true,
            ..Default::default()
        })
        .await
        .expect("consume rpc");
    let mut values = Vec::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(4);
    while tokio::time::Instant::now() < deadline {
        match tokio::time::timeout(std::time::Duration::from_millis(700), stream.next()).await {
            Ok(Some(Ok(chunk))) => {
                assert_eq!(chunk.error_code, 0, "consume error: {chunk:?}");
                for rec in chunk.records {
                    values.push(String::from_utf8(rec.value).expect("utf8"));
                }
                if !values.is_empty() {
                    break;
                }
            }
            Ok(Some(Err(e))) => panic!("consume stream error: {e:?}"),
            Ok(None) => break,
            Err(_) => break,
        }
    }
    values
}

fn broker_or_skip() -> Option<String> {
    match std::env::var("KAFKA_PROXY_E2E_BROKER") {
        Ok(b) => Some(b),
        Err(_) => {
            eprintln!("KAFKA_PROXY_E2E_BROKER unset: skipping");
            None
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_multi_broker_leader_routing() {
    if std::env::var("KAFKA_PROXY_E2E_CLUSTER").ok().as_deref() != Some("1") {
        eprintln!("KAFKA_PROXY_E2E_CLUSTER != 1: skipping");
        return;
    }
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-cluster");
    let created = client
        .create_topics(pb::CreateTopicsRequest {
            topics: vec![pb::NewTopic {
                name: topic.clone(),
                num_partitions: 6,
                replication_factor: 2,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("create cluster topic");
    assert_eq!(created.results[0].error_code, 0, "{created:?}");
    // Leaders must span more than this bootstrap broker.
    let mut leaders = std::collections::HashSet::new();
    let mut broker_count = 0;
    for _ in 0..30 {
        let meta = client
            .metadata(pb::MetadataRequest {
                topics: vec![topic.clone()],
                ..Default::default()
            })
            .await
            .expect("cluster metadata");
        broker_count = meta.brokers.len();
        leaders = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .map(|t| t.partitions.iter().map(|p| p.leader_id).collect())
            .unwrap_or_default();
        if broker_count >= 2 && leaders.len() > 1 && !leaders.contains(&-1) {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    assert!(broker_count >= 2, "expected >=2 brokers, got {broker_count}");
    assert!(
        leaders.len() > 1,
        "partition leaders do not span brokers: {leaders:?}"
    );
    // Produce + consume one record on every partition through a
    // client bootstrapped only to the first node; non-leader
    // partitions only work if the proxy routes by leader.
    for partition in 0..6 {
        let value = format!("cluster-p{partition}");
        let produced = client
            .produce(pb::ProduceRequest {
                topic: topic.clone(),
                partition,
                records: vec![record(&value)],
                acks: pb::Acks::AcksAll,
                ..Default::default()
            })
            .await
            .expect("cluster produce");
        assert_eq!(produced.error_code, 0, "p{partition}: {produced:?}");
        let mut stream = client
            .consume(pb::ConsumeRequest {
                topic: topic.clone(),
                partition,
                offset: -2,
                max_records: 10,
                max_wait_ms: 2_000,
                ..Default::default()
            })
            .await
            .expect("cluster consume");
        let mut got = Vec::new();
        let collect = async {
            while got.len() < 1 {
                match stream.next().await {
                    Some(Ok(chunk)) => {
                        assert_eq!(chunk.error_code, 0, "p{partition}: {chunk:?}");
                        for rec in chunk.records {
                            got.push(String::from_utf8(rec.value).expect("utf8"));
                        }
                    }
                    Some(Err(e)) => panic!("cluster consume error: {e:?}"),
                    None => break,
                }
            }
        };
        tokio::time::timeout(std::time::Duration::from_secs(30), collect)
            .await
            .expect("cluster consume timed out");
        assert_eq!(got, vec![value], "partition {partition}");
    }
}

fn record(value: &str) -> pb::Record {
    pb::Record {
        key: format!("key-{value}").into_bytes(),
        value: value.as_bytes().to_vec(),
        headers: vec![pb::Header {
            key: "h1".to_string(),
            value: b"hv".to_vec(),
            ..Default::default()
        }],
        ..Default::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_roundtrip() {
    let Ok(broker) = std::env::var("KAFKA_PROXY_E2E_BROKER") else {
        eprintln!("KAFKA_PROXY_E2E_BROKER unset: skipping");
        return;
    };

    let (a, b) = loopback_pair();
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: broker.clone(),
        client_id: "grpc-dc-kafka-proxy-e2e".to_string(),
        sasl: None,
        tls: None,
    }));
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![kafka_service(service)]));

    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    let client = KafkaClient::new(Channel::new(client_transport));

    let topic = format!(
        "grpc-dc-e2e-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    );

    let created = client
        .create_topics(pb::CreateTopicsRequest {
            topics: vec![pb::NewTopic {
                name: topic.clone(),
                num_partitions: 1,
                replication_factor: 1,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("create topic rpc");
    assert_eq!(created.results.len(), 1);
    assert_eq!(created.results[0].error_code, 0, "topic creation failed: {created:?}");

    // Wait until the topic shows up in metadata.
    let mut partitions = 0;
    for _ in 0..50 {
        let meta = client
            .metadata(pb::MetadataRequest {
                topics: vec![topic.clone()],
                ..Default::default()
            })
            .await
            .expect("metadata rpc");
        partitions = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .map(|t| t.partitions.len())
            .unwrap_or(0);
        if partitions == 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    assert_eq!(partitions, 1, "topic never became visible");

    let mut expected_base = 0i64;
    for value in ["alpha", "beta", "gamma"] {
        let produced = client
            .produce(pb::ProduceRequest {
                topic: topic.clone(),
                partition: 0,
                records: vec![record(value)],
                acks: pb::Acks::AcksAll,
                ..Default::default()
            })
            .await
            .expect("produce rpc");
        assert_eq!(produced.error_code, 0, "produce failed: {produced:?}");
        assert_eq!(produced.partition, 0);
        assert_eq!(produced.base_offset, expected_base);
        expected_base += 1;
    }

    let offsets = client
        .list_offsets(pb::ListOffsetsRequest {
            topic: topic.clone(),
            partition: 0,
            timestamp: -1,
            ..Default::default()
        })
        .await
        .expect("list offsets rpc");
    assert_eq!(offsets.error_code, 0);
    assert_eq!(offsets.offset, 3, "high watermark should be 3");

    // Consume the three records back, in order.
    let mut stream = client
        .consume(pb::ConsumeRequest {
            topic: topic.clone(),
            partition: 0,
            offset: -2,
            max_records: 10,
            max_wait_ms: 2_000,
            ..Default::default()
        })
        .await
        .expect("consume rpc");
    let mut values: Vec<String> = Vec::new();
    let mut header_seen = false;
    let collect = async {
        while values.len() < 3 {
            match stream.next().await {
                Some(Ok(chunk)) => {
                    assert_eq!(chunk.error_code, 0, "consume error: {chunk:?}");
                    for rec in chunk.records {
                        if rec.headers.iter().any(|h| h.key == "h1" && h.value == b"hv") {
                            header_seen = true;
                        }
                        values.push(String::from_utf8(rec.value).expect("utf8 value"));
                    }
                }
                Some(Err(e)) => panic!("consume stream error: {e:?}"),
                None => break,
            }
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(30), collect)
        .await
        .expect("consume timed out");
    assert_eq!(values, vec!["alpha", "beta", "gamma"]);
    assert!(header_seen, "record header roundtripped");
    drop(stream);

    // Offsets: commit then fetch back.
    let group = format!("{topic}-group");
    let commit = client
        .commit_offset(pb::CommitOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            partition: 0,
            committed_offset: 3,
            metadata: "e2e".to_string(),
            ..Default::default()
        })
        .await
        .expect("commit rpc");
    assert_eq!(commit.error_code, 0, "commit failed: {commit:?}");
    let fetched = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group,
            topic: topic.clone(),
            partition: 0,
            ..Default::default()
        })
        .await
        .expect("fetch offset rpc");
    assert_eq!(fetched.error_code, 0);
    assert_eq!(fetched.committed_offset, 3);
    assert_eq!(fetched.metadata, "e2e");

    let deleted = client
        .delete_topics(pb::DeleteTopicsRequest {
            topics: vec![topic.clone()],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("delete topics rpc");
    assert_eq!(deleted.results.len(), 1);
    assert_eq!(deleted.results[0].error_code, 0, "delete failed: {deleted:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_compression() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    for (name, compression) in [
        ("gzip", pb::Compression::CompressionGzip),
        ("snappy", pb::Compression::CompressionSnappy),
        ("lz4", pb::Compression::CompressionLz4),
        ("zstd", pb::Compression::CompressionZstd),
    ] {
        let topic = unique_topic(&format!("grpc-dc-e2e-{name}"));
        make_topic(&client, &topic, 1).await;
        let produced = client
            .produce(pb::ProduceRequest {
                topic: topic.clone(),
                partition: 0,
                records: vec![record("one"), record("two"), record("three")],
                acks: pb::Acks::AcksAll,
                compression,
                ..Default::default()
            })
            .await
            .expect("compressed produce rpc");
        assert_eq!(produced.error_code, 0, "{name} produce failed: {produced:?}");
        let values = consume_values(&client, &topic, 3).await;
        assert_eq!(values, vec!["one", "two", "three"], "{name} roundtrip");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_idempotent_and_transactions() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-txn");
    make_topic(&client, &topic, 1).await;

    // Idempotent producer session.
    let opened = client
        .open_producer(pb::OpenProducerRequest::default())
        .await
        .expect("open producer rpc");
    assert_eq!(opened.error_code, 0, "open producer failed: {opened:?}");
    assert!(opened.producer_id >= 0);
    let first = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("idem-1")],
            acks: pb::Acks::AcksAll,
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("idempotent produce");
    assert_eq!(first.error_code, 0, "{first:?}");
    assert_eq!(first.base_offset, 0);

    // Transactional producer: commit path.
    let txn_id = unique_topic("grpc-dc-txn");
    let opened_txn = client
        .open_producer(pb::OpenProducerRequest {
            transactional_id: txn_id,
            transaction_timeout_ms: 60_000,
            ..Default::default()
        })
        .await
        .expect("open transactional producer");
    assert_eq!(opened_txn.error_code, 0, "open txn failed: {opened_txn:?}");
    let in_txn = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("txn-1")],
            acks: pb::Acks::AcksAll,
            session_id: opened_txn.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("txn produce");
    assert_eq!(in_txn.error_code, 0, "{in_txn:?}");
    let ended = client
        .end_transaction(pb::EndTransactionRequest {
            session_id: opened_txn.session_id.clone(),
            commit: true,
            ..Default::default()
        })
        .await
        .expect("end transaction");
    assert_eq!(ended.error_code, 0, "commit failed: {ended:?}");

    let values = consume_values(&client, &topic, 2).await;
    assert_eq!(values, vec!["idem-1", "txn-1"]);

    let closed = client
        .close_producer(pb::CloseProducerRequest {
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("close producer");
    assert_eq!(closed.error_code, 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_transactional_consume_produce() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let source = unique_topic("grpc-dc-e2e-cp-src");
    let sink = unique_topic("grpc-dc-e2e-cp-sink");
    make_topic(&client, &source, 1).await;
    make_topic(&client, &sink, 1).await;
    for value in ["cp-1", "cp-2"] {
        let produced = produce_one(&client, &source, value).await;
        assert_eq!(produced.error_code, 0, "{produced:?}");
    }
    let seen = consume_values(&client, &source, 2).await;
    assert_eq!(seen, vec!["cp-1", "cp-2"]);

    let group = format!("{source}-cp-group");
    async fn do_txn(
        client: &KafkaClient,
        source: &str,
        sink: &str,
        group: &str,
    ) -> String {
        let txn_id = unique_topic("grpc-dc-cp-txn");
        let opened = client
            .open_producer(pb::OpenProducerRequest {
                transactional_id: txn_id,
                transaction_timeout_ms: 60_000,
                ..Default::default()
            })
            .await
            .expect("open cp producer");
        assert_eq!(opened.error_code, 0, "open cp txn failed: {opened:?}");
        let session_id = opened.session_id.clone();
        let produced = client
            .produce(pb::ProduceRequest {
                topic: sink.to_string(),
                partition: 0,
                records: vec![record("cp-out")],
                acks: pb::Acks::AcksAll,
                session_id: session_id.clone(),
                ..Default::default()
            })
            .await
            .expect("cp txn produce");
        assert_eq!(produced.error_code, 0, "{produced:?}");
        let staged = client
            .commit_offset(pb::CommitOffsetRequest {
                group_id: group.to_string(),
                topic: source.to_string(),
                partition: 0,
                committed_offset: 2,
                metadata: String::new(),
                session_id: session_id.clone(),
                ..Default::default()
            })
            .await
            .expect("stage txn offset");
        assert_eq!(staged.error_code, 0, "{staged:?}");
        session_id
    }

    // Committed path: records + offset become visible at commit.
    let session_id = do_txn(&client, &source, &sink, &group).await;
    let committed_visible_before = drain_committed_window(&client, &sink).await;
    let ended = client
        .end_transaction(pb::EndTransactionRequest {
            session_id,
            commit: true,
            ..Default::default()
        })
        .await
        .expect("cp end transaction");
    assert_eq!(ended.error_code, 0, "cp commit failed: {ended:?}");
    assert!(
        committed_visible_before.is_empty(),
        "read_committed saw uncommitted records: {committed_visible_before:?}"
    );
    let visible = drain_committed_window(&client, &sink).await;
    assert_eq!(visible, vec!["cp-out"]);
    let fetched = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group.clone(),
            topic: source.clone(),
            partition: 0,
            ..Default::default()
        })
        .await
        .expect("fetch cp offset");
    assert_eq!(fetched.error_code, 0);
    assert_eq!(fetched.committed_offset, 2, "offset not committed with txn: {fetched:?}");

    // Aborted path: staged offset must not persist.
    let group2 = format!("{source}-cp-group-abort");
    let session2 = do_txn(&client, &source, &sink, &group2).await;
    let ended2 = client
        .end_transaction(pb::EndTransactionRequest {
            session_id: session2,
            commit: false,
            ..Default::default()
        })
        .await
        .expect("cp abort transaction");
    assert_eq!(ended2.error_code, 0, "cp abort failed: {ended2:?}");
    let fetched2 = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group2.clone(),
            topic: source.clone(),
            partition: 0,
            ..Default::default()
        })
        .await
        .expect("fetch aborted offset");
    assert_eq!(fetched2.error_code, 0);
    assert_eq!(
        fetched2.committed_offset, -1,
        "aborted txn offset leaked: {fetched2:?}"
    );
    // Aborted cp-out must stay invisible to read_committed:
    // only the first committed record is ever visible.
    let still = drain_committed_window(&client, &sink).await;
    assert_eq!(still, vec!["cp-out"], "read_committed saw aborted record");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_consumer_group() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-group");
    make_topic(&client, &topic, 1).await;
    for value in ["g1", "g2", "g3"] {
        let produced = produce_one(&client, &topic, value).await;
        assert_eq!(produced.error_code, 0, "{produced:?}");
    }

    let group = format!("{topic}-consumers");
    let mut stream = client
        .subscribe(pb::GroupSubscribeRequest {
            group_id: group.clone(),
            topics: vec![topic.clone()],
            session_timeout_ms: 30_000,
            max_poll_records: 10,
            auto_offset_reset: "earliest".to_string(),
            ..Default::default()
        })
        .await
        .expect("subscribe rpc");

    let mut assigned = false;
    let mut values: Vec<String> = Vec::new();
    let collect = async {
        while values.len() < 3 {
            match stream.next().await {
                Some(Ok(event)) => {
                    if let Some(assignment) = event.assignment {
                        assert!(!assignment.member_id.is_empty());
                        assert_eq!(assignment.partitions.len(), 1);
                        assert_eq!(assignment.partitions[0].topic, topic);
                        assigned = true;
                    }
                    if let Some(batch) = event.batch {
                        for rec in batch.records {
                            values.push(String::from_utf8(rec.value).expect("utf8"));
                        }
                    }
                    if let Some(error) = event.group_error {
                        panic!("group error {}: {}", error.error_code, error.message);
                    }
                }
                Some(Err(e)) => panic!("subscribe stream error: {e:?}"),
                None => break,
            }
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(60), collect)
        .await
        .expect("group consume timed out");
    assert!(assigned, "received an assignment");
    assert_eq!(values, vec!["g1", "g2", "g3"]);

    // Committing through the live group session must work.
    let commit = client
        .commit_offset(pb::CommitOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            partition: 0,
            committed_offset: 3,
            metadata: "group-e2e".to_string(),
            ..Default::default()
        })
        .await
        .expect("group commit rpc");
    assert_eq!(commit.error_code, 0, "group commit failed: {commit:?}");
    drop(stream);

    let fetched = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group,
            topic: topic.clone(),
            partition: 0,
            ..Default::default()
        })
        .await
        .expect("fetch offset rpc");
    assert_eq!(fetched.error_code, 0);
    assert_eq!(fetched.committed_offset, 3);
}
