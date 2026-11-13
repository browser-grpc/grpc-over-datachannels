//! KIP-932 share group coverage: queue-style consume with
//! explicit acknowledgements (ACCEPT retires, RELEASE
//! redelivers with an incremented delivery count).
//!
//! Set KAFKA_PROXY_E2E_BROKER=host:port to run (Apache Kafka
//! with share groups; Redpanda does not implement KIP-932).
//! Without it the test is a no-op so plain `cargo test` stays
//! green on machines without a broker. If the broker refuses
//! the share heartbeat, the test reports and returns rather
//! than failing a broker that cannot run share groups.

use kafka_native::client::KafkaConfig;
use kafka_native::service::KafkaService;
use kafka_native::{pb, stub};
use grpc_dc::{loopback_pair, Channel, DcTransport, Server};
use std::sync::Arc;
use stub::{kafka_service, KafkaClient};

async fn setup(broker: &str) -> KafkaClient {
    let (a, b) = loopback_pair();
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: broker.to_string(),
        client_id: "grpc-dc-kafka-share-e2e".to_string(),
        sasl: None,
        tls: None,
    }));
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![kafka_service(service)]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    KafkaClient::new(Channel::new(client_transport))
}

fn unique(prefix: &str) -> String {
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

async fn poll(client: &KafkaClient, session: &str, want: usize) -> Vec<pb::SharePollRecord> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut out = Vec::new();
    while out.len() < want && std::time::Instant::now() < deadline {
        let resp = client
            .share_poll(pb::SharePollRequest {
                session_id: session.to_string(),
                max_records: 10,
                max_wait_ms: 500,
                ..Default::default()
            })
            .await
            .expect("share poll");
        assert_eq!(resp.error_code, 0, "share poll failed: {resp:?}");
        out.extend(resp.records);
        if out.is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_share_group_accept_and_release() {
    let Some(broker_addr) = std::env::var("KAFKA_PROXY_E2E_BROKER").ok().filter(|v| !v.is_empty())
    else {
        eprintln!("KAFKA_PROXY_E2E_BROKER unset: skipping");
        return;
    };
    let client = setup(&broker_addr).await;
    let topic = unique("grpcdc-share-topic");
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
        .expect("create topics");
    assert_eq!(created.results[0].error_code, 0, "{created:?}");

    let group = unique("grpcdc-share-group");
    let opened = client
        .open_share_group(pb::OpenShareGroupRequest {
            group_id: group.clone(),
            topics: vec![topic.clone()],
            ..Default::default()
        })
        .await
        .expect("open share group");
    if opened.error_code != 0 {
        eprintln!(
            "broker refused share group (error {}): KIP-932 unavailable here, skipping",
            opened.error_code
        );
        return;
    }
    let session = opened.session_id.clone();
    assert!(!session.is_empty(), "{opened:?}");
    // Assignment settles asynchronously (bounded in the
    // service); it may still be empty here. Delivery below
    // proves it arrived; no assignment + no delivery means
    // the broker cannot initialize share state (skip there).
    let assignment_empty = opened
        .assignment
        .as_ref()
        .map(|a| a.partitions.is_empty())
        .unwrap_or(true);

    // Initialize the share partition before producing: a
    // share partition's start offset is taken when it is
    // first fetched, so records produced before any fetch
    // are not delivered. One empty poll initializes it
    // (verified against the reference share consumer).
    let init = client
        .share_poll(pb::SharePollRequest {
            session_id: session.clone(),
            max_records: 10,
            max_wait_ms: 500,
            ..Default::default()
        })
        .await
        .expect("share poll init");
    assert_eq!(init.error_code, 0, "{init:?}");
    assert!(init.records.is_empty(), "{init:?}");

    let produced = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("s1"), record("s2")],
            acks: pb::Acks::AcksAll,
            ..Default::default()
        })
        .await
        .expect("produce");
    assert_eq!(produced.error_code, 0, "{produced:?}");

    // First delivery of both records.
    let first = poll(&client, &session, 2).await;
    if first.is_empty() && assignment_empty {
        // The coordinator never assigned and nothing
        // delivers: this broker cannot initialize share state
        // (e.g. a combined-mode SASL fixture whose share
        // persister cannot authenticate internally — the
        // reference share consumer stalls identically there).
        eprintln!("share assignment never delivered on this broker: skipping");
        return;
    }
    assert_eq!(first.len(), 2, "share delivery timed out: {first:?}");
    let values: Vec<String> = first
        .iter()
        .map(|r| String::from_utf8(r.value.clone()).expect("utf8"))
        .collect();
    assert_eq!(values, vec!["s1", "s2"], "{first:?}");
    assert!(
        first.iter().all(|r| r.delivery_count == 1),
        "first delivery must have count 1: {first:?}"
    );

    // ACCEPT retires them; a follow-up poll stays empty.
    let acked = client
        .share_ack(pb::ShareAckRequest {
            session_id: session.clone(),
            entries: first
                .iter()
                .map(|r| pb::ShareAckEntry {
                    topic: topic.clone(),
                    partition: 0,
                    offset: r.offset,
                    ack_type: 1,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        })
        .await
        .expect("share ack accept");
    assert_eq!(acked.error_code, 0, "{acked:?}");
    let empty = client
        .share_poll(pb::SharePollRequest {
            session_id: session.clone(),
            max_records: 10,
            max_wait_ms: 500,
            ..Default::default()
        })
        .await
        .expect("share poll after accept");
    assert_eq!(empty.error_code, 0, "{empty:?}");
    assert!(empty.records.is_empty(), "accepted records redelivered: {empty:?}");

    // ShareGroupDescribe sees the live member + assignment.
    let described = client
        .describe_share_groups(pb::DescribeShareGroupsRequest {
            group_ids: vec![group.clone()],
            ..Default::default()
        })
        .await
        .expect("describe share groups");
    assert_eq!(described.groups.len(), 1, "{described:?}");
    let desc = &described.groups[0];
    assert_eq!(desc.error_code, 0, "{desc:?}");
    assert_eq!(desc.group_id, group, "{desc:?}");
    assert!(!desc.state.is_empty(), "{desc:?}");
    assert_eq!(desc.members.len(), 1, "{desc:?}");
    assert!(
        desc.members[0]
            .assignment
            .iter()
            .any(|tp| tp.topic == topic && tp.partition == 0),
        "member assignment must cover the topic partition: {desc:?}"
    );

    // RELEASE redelivers with delivery_count incremented.
    let produced = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("s3")],
            acks: pb::Acks::AcksAll,
            ..Default::default()
        })
        .await
        .expect("produce s3");
    assert_eq!(produced.error_code, 0, "{produced:?}");
    let third = poll(&client, &session, 1).await;
    assert_eq!(third.len(), 1, "share delivery of s3 timed out: {third:?}");
    assert_eq!(third[0].delivery_count, 1, "{third:?}");
    let released = client
        .share_ack(pb::ShareAckRequest {
            session_id: session.clone(),
            entries: vec![pb::ShareAckEntry {
                topic: topic.clone(),
                partition: 0,
                offset: third[0].offset,
                ack_type: 2,
                ..Default::default()
            }],
            ..Default::default()
        })
        .await
        .expect("share ack release");
    assert_eq!(released.error_code, 0, "{released:?}");
    let redelivered = poll(&client, &session, 1).await;
    assert_eq!(redelivered.len(), 1, "release redelivery timed out: {redelivered:?}");
    assert_eq!(redelivered[0].offset, third[0].offset, "{redelivered:?}");
    assert_eq!(redelivered[0].delivery_count, 2, "RELEASE must bump delivery count: {redelivered:?}");

    let closed = client
        .close_share_group(pb::CloseShareGroupRequest {
            session_id: session.clone(),
            ..Default::default()
        })
        .await
        .expect("close share group");
    assert_eq!(closed.error_code, 0, "{closed:?}");

    let deleted = client
        .delete_topics(pb::DeleteTopicsRequest {
            topics: vec![topic.clone()],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("delete topics");
    assert_eq!(deleted.results[0].error_code, 0, "{deleted:?}");
}
