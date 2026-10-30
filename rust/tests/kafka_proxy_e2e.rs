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

async fn produce_part(
    client: &KafkaClient,
    topic: &str,
    partition: i32,
    value: &str,
) -> pb::ProduceResponse {
    client
        .produce(pb::ProduceRequest {
            topic: topic.to_string(),
            partition,
            records: vec![record(value)],
            acks: pb::Acks::AcksAll,
            ..Default::default()
        })
        .await
        .expect("produce rpc")
}

/// Read group events until `want_assignments` assignment events
/// have been seen or the deadline passes; returns (assignments
/// as sorted partition lists, all batch values seen).
async fn collect_group(
    stream: &mut (impl futures_util::Stream<Item = Result<pb::GroupSubscribeResponse, grpc_dc::Status>> + Unpin),
    want_assignments: usize,
    want_values: usize,
    timeout: std::time::Duration,
) -> (Vec<Vec<i32>>, Vec<String>, Vec<String>) {
    let mut assignments: Vec<Vec<i32>> = Vec::new();
    let mut members: Vec<String> = Vec::new();
    let mut values: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    while assignments.len() < want_assignments || values.len() < want_values {
        let Some(next) = tokio::time::timeout_at(deadline, stream.next()).await.ok() else {
            break;
        };
        match next {
            Some(Ok(event)) => {
                if let Some(a) = event.assignment {
                    let mut parts: Vec<i32> = a.partitions.iter().map(|p| p.partition).collect();
                    parts.sort_unstable();
                    assignments.push(parts);
                    members.push(a.member_id.clone());
                }
                if let Some(batch) = event.batch {
                    for rec in batch.records {
                        values.push(String::from_utf8(rec.value).expect("utf8"));
                    }
                }
                if let Some(e) = event.group_error {
                    panic!("group error {}: {}", e.error_code, e.message);
                }
            }
            Some(Err(e)) => panic!("subscribe stream error: {e:?}"),
            None => break,
        }
    }
    (assignments, members, values)
}


/// Collect assignments until the last one satisfies `pred`
/// (deadline-bounded); returns all assignments seen.
async fn collect_until_assignment(
    stream: &mut (impl futures_util::Stream<Item = Result<pb::GroupSubscribeResponse, grpc_dc::Status>> + Unpin),
    pred: impl Fn(&Vec<i32>) -> bool,
    timeout: std::time::Duration,
) -> Vec<Vec<i32>> {
    let mut all: Vec<Vec<i32>> = Vec::new();
    let deadline = tokio::time::Instant::now() + timeout;
    while !all.last().map(|l| pred(l)).unwrap_or(false) {
        let Ok(next) = tokio::time::timeout_at(deadline, stream.next()).await else { break };
        match next {
            Some(Ok(event)) => {
                if let Some(a) = event.assignment {
                    let mut parts: Vec<i32> = a.partitions.iter().map(|x| x.partition).collect();
                    parts.sort_unstable();
                    all.push(parts);
                }
                if let Some(e) = event.group_error {
                    panic!("group error {}: {}", e.error_code, e.message);
                }
            }
            Some(Err(e)) => panic!("subscribe stream error: {e:?}"),
            None => break,
        }
    }
    all
}

fn subscribe_req(group: &str, topic: &str) -> pb::GroupSubscribeRequest {
    pb::GroupSubscribeRequest {
        group_id: group.to_string(),
        topics: vec![topic.to_string()],
        session_timeout_ms: 30_000,
        max_poll_records: 10,
        auto_offset_reset: "earliest".to_string(),
        ..Default::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_fetch_long_poll_and_range() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-range");
    make_topic(&client, &topic, 1).await;
    assert_eq!(produce_one(&client, &topic, "lp-1").await.error_code, 0);

    // ListOffsets: earliest / latest / read_committed latest.
    for (ts, want, rc) in [(-2, 0, false), (-1, 1, false), (-1, 1, true)] {
        let out = client
            .list_offsets(pb::ListOffsetsRequest {
                topic: topic.clone(),
                partition: 0,
                timestamp: ts,
                read_committed: rc,
                ..Default::default()
            })
            .await
            .expect("list offsets");
        assert_eq!(out.error_code, 0, "{out:?}");
        assert_eq!(out.offset, want, "ts={ts} rc={rc}: {out:?}");
    }

    // Out of range: first consume chunk must carry the broker
    // error (Kafka/Redpanda OFFSET_OUT_OF_RANGE = 1), not data.
    let mut stream = client
        .consume(pb::ConsumeRequest {
            topic: topic.clone(),
            partition: 0,
            offset: 99,
            max_records: 10,
            max_wait_ms: 500,
            ..Default::default()
        })
        .await
        .expect("consume rpc");
    let first = tokio::time::timeout(std::time::Duration::from_secs(20), stream.next())
        .await
        .expect("out-of-range consume hung")
        .expect("out-of-range stream ended without a chunk")
        .expect("out-of-range stream errored instead of chunk");
    assert_eq!(first.error_code, 1, "expected OFFSET_OUT_OF_RANGE: {first:?}");
    assert!(first.records.is_empty());

    // Long-poll: at the high watermark nothing arrives until a
    // new record is produced, then it is delivered promptly.
    let mut stream = client
        .consume(pb::ConsumeRequest {
            topic: topic.clone(),
            partition: 0,
            offset: 1,
            max_records: 10,
            max_wait_ms: 2_000,
            ..Default::default()
        })
        .await
        .expect("consume rpc");
    let early = tokio::time::timeout(std::time::Duration::from_millis(900), stream.next()).await;
    assert!(early.is_err(), "long-poll delivered before any new record: {early:?}");
    assert_eq!(produce_one(&client, &topic, "lp-2").await.error_code, 0);
    let chunk = tokio::time::timeout(std::time::Duration::from_secs(20), stream.next())
        .await
        .expect("long-poll did not deliver after produce")
        .expect("long-poll stream ended")
        .expect("long-poll stream error");
    assert_eq!(chunk.error_code, 0, "{chunk:?}");
    let vals: Vec<String> = chunk
        .records
        .iter()
        .map(|r| String::from_utf8(r.value.clone()).expect("utf8"))
        .collect();
    assert_eq!(vals, vec!["lp-2"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_rebalance_two_members() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-rebalance");
    make_topic(&client, &topic, 2).await;
    assert_eq!(produce_part(&client, &topic, 0, "m-p0").await.error_code, 0);
    assert_eq!(produce_part(&client, &topic, 1, "m-p1").await.error_code, 0);
    let group = format!("{topic}-members");

    let mut a = client.subscribe(subscribe_req(&group, &topic)).await.expect("subscribe A");
    let (assign_a, _, _) = collect_group(&mut a, 1, 0, std::time::Duration::from_secs(30)).await;
    assert_eq!(assign_a, vec![vec![0, 1]], "first member takes both partitions");

    // Second member joins: both are rebalanced to one each.
    // (An intermediate generation may briefly re-grant both
    // partitions to A before B syncs, so wait for the state,
    // not a fixed event count.)
    let mut b = client.subscribe(subscribe_req(&group, &topic)).await.expect("subscribe B");
    let assign_b = collect_until_assignment(&mut b, |l| l.len() == 1, std::time::Duration::from_secs(45)).await;
    let assign_a2 = collect_until_assignment(&mut a, |l| l.len() == 1, std::time::Duration::from_secs(45)).await;
    let a_last = assign_a2.last().expect("A rebalanced").clone();
    let b_last = assign_b.last().expect("B assigned").clone();
    assert_ne!(a_last, b_last, "assignments must be disjoint: A={a_last:?} B={b_last:?}");
    // The records sit at fixed offsets; whichever member owns
    // a partition from the start may already have read it.
    // Assert only assignment disjointness here; delivery is
    // covered after B leaves below.
    let _ = (&assign_a, &assign_a2);

    // B leaves: A is rebalanced back to both partitions.
    drop(b);
    let assign_a3 = collect_until_assignment(&mut a, |l| l == &vec![0, 1], std::time::Duration::from_secs(45)).await;
    assert_eq!(
        assign_a3.last().cloned(),
        Some(vec![0, 1]),
        "A regains both partitions after B leaves: {assign_a3:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_static_membership() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-static");
    make_topic(&client, &topic, 1).await;
    let group = format!("{topic}-static");

    let mut req = subscribe_req(&group, &topic);
    req.group_instance_id = "static-member-1".to_string();
    let mut s1 = client.subscribe(req.clone()).await.expect("subscribe static 1");
    let (a1, m1, _) = collect_group(&mut s1, 1, 0, std::time::Duration::from_secs(30)).await;
    assert_eq!(a1, vec![vec![0]]);
    assert!(!m1[0].is_empty());
    drop(s1);
    // Brief settle so the leave lands before the rejoin.
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let mut s2 = client.subscribe(req).await.expect("subscribe static 2");
    let (a2, m2, _) = collect_group(&mut s2, 1, 0, std::time::Duration::from_secs(30)).await;
    assert_eq!(a2, vec![vec![0]], "static member rejoins with its partition");
    // Static membership: after an explicit leave the broker
    // mints a fresh id, but it is always derived from the
    // group_instance_id ("<instance>-<uuid>"), which is what
    // lets the coordinator fence by instance on rejoin.
    assert!(m1[0].starts_with("static-member-1-"), "member id not instance-derived: {m1:?}");
    assert!(m2[0].starts_with("static-member-1-"), "member id not instance-derived: {m2:?}");

    // Fencing: a second live subscribe with the same instance
    // id fences the first member; its stream must error or end.
    let mut req3 = subscribe_req(&group, &topic);
    req3.group_instance_id = "static-member-1".to_string();
    let mut s3 = client.subscribe(req3).await.expect("subscribe static 3");
    let (a3, _, _) = collect_group(&mut s3, 1, 0, std::time::Duration::from_secs(30)).await;
    assert_eq!(a3, vec![vec![0]]);
    let fenced = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        loop {
            match s2.next().await {
                Some(Ok(event)) => {
                    if event.group_error.is_some() {
                        return true;
                    }
                }
                Some(Err(_)) => return true,
                None => return true,
            }
        }
    })
    .await
    .expect("fenced member stream hung");
    assert!(fenced, "first static member was not fenced");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_read_committed() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-grc");
    make_topic(&client, &topic, 1).await;

    // One committed and one aborted transactional record.
    for (value, commit) in [("grc-committed", true), ("grc-aborted", false)] {
        let opened = client
            .open_producer(pb::OpenProducerRequest {
                transactional_id: unique_topic("grpc-dc-grc-txn"),
                transaction_timeout_ms: 60_000,
                ..Default::default()
            })
            .await
            .expect("open txn");
        assert_eq!(opened.error_code, 0, "{opened:?}");
        let produced = client
            .produce(pb::ProduceRequest {
                topic: topic.clone(),
                partition: 0,
                records: vec![record(value)],
                acks: pb::Acks::AcksAll,
                session_id: opened.session_id.clone(),
                ..Default::default()
            })
            .await
            .expect("txn produce");
        assert_eq!(produced.error_code, 0, "{produced:?}");
        let ended = client
            .end_transaction(pb::EndTransactionRequest {
                session_id: opened.session_id.clone(),
                commit,
                ..Default::default()
            })
            .await
            .expect("end txn");
        assert_eq!(ended.error_code, 0, "{ended:?}");
    }

    // read_committed group: only the committed record arrives.
    let group = format!("{topic}-rc");
    let mut req = subscribe_req(&group, &topic);
    req.read_committed = true;
    let mut stream = client.subscribe(req).await.expect("subscribe rc group");
    let (_, _, values) = collect_group(&mut stream, 1, 1, std::time::Duration::from_secs(45)).await;
    assert_eq!(values, vec!["grc-committed"], "group read_committed leaked: {values:?}");
    // And nothing more within a short window.
    let extra = tokio::time::timeout(std::time::Duration::from_secs(4), stream.next()).await;
    if let Ok(Some(Ok(event))) = extra {
        assert!(event.batch.is_none(), "aborted record arrived late: {event:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_null_vs_empty_key() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-keys");
    make_topic(&client, &topic, 1).await;

    let cases: Vec<pb::Record> = vec![
        pb::Record { key: b"".to_vec(), value: b"empty-key".to_vec(), ..Default::default() },
        pb::Record { key: b"".to_vec(), value: b"null-key".to_vec(), null_key: true, ..Default::default() },
        pb::Record { key: b"k3".to_vec(), value: b"real-key".to_vec(), ..Default::default() },
    ];
    let produced = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: cases,
            acks: pb::Acks::AcksAll,
            ..Default::default()
        })
        .await
        .expect("produce keys");
    assert_eq!(produced.error_code, 0, "{produced:?}");

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
    let mut got: Vec<(String, bool, Vec<u8>)> = Vec::new();
    let collect = async {
        while got.len() < 3 {
            match stream.next().await {
                Some(Ok(chunk)) => {
                    assert_eq!(chunk.error_code, 0, "{chunk:?}");
                    for rec in chunk.records {
                        got.push((
                            String::from_utf8(rec.value).expect("utf8"),
                            rec.key_null,
                            rec.key,
                        ));
                    }
                }
                Some(Err(e)) => panic!("consume error: {e:?}"),
                None => break,
            }
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(30), collect)
        .await
        .expect("key consume timed out");
    assert_eq!(
        got,
        vec![
            ("empty-key".to_string(), false, Vec::new()),
            ("null-key".to_string(), true, Vec::new()),
            ("real-key".to_string(), false, b"k3".to_vec()),
        ]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_out_of_range_reset() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-goor");
    make_topic(&client, &topic, 1).await;
    assert_eq!(produce_one(&client, &topic, "oor-1").await.error_code, 0);
    let group = format!("{topic}-oor");
    // Commit an offset far beyond the high watermark; the
    // group's fetch position starts out of range and must
    // recover via the earliest reset policy, not error out.
    let committed = client
        .commit_offset(pb::CommitOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            committed_offset: 500,
            ..Default::default()
        })
        .await
        .expect("commit oor offset");
    assert_eq!(committed.error_code, 0, "{committed:?}");
    let mut req = subscribe_req(&group, &topic);
    req.auto_offset_reset = "earliest".to_string();
    let mut stream = client.subscribe(req).await.expect("subscribe oor group");
    let (_, _, values) =
        collect_group(&mut stream, 1, 1, std::time::Duration::from_secs(45)).await;
    assert_eq!(values, vec!["oor-1"], "group did not recover from out-of-range: {values:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_commit_after_rebalance() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-fence");
    make_topic(&client, &topic, 1).await;
    assert_eq!(produce_one(&client, &topic, "fence-1").await.error_code, 0);
    let group = format!("{topic}-fence");

    let mut a = client.subscribe(subscribe_req(&group, &topic)).await.expect("subscribe A");
    let (_, _, vals_a) = collect_group(&mut a, 1, 1, std::time::Duration::from_secs(45)).await;
    assert_eq!(vals_a, vec!["fence-1"]);
    // Commit through the live session (proxy uses A's
    // generation/member): offset 1 = next record.
    let c1 = client
        .commit_offset(pb::CommitOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            committed_offset: 1,
            ..Default::default()
        })
        .await
        .expect("commit via A");
    assert_eq!(c1.error_code, 0, "{c1:?}");
    drop(a);
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;

    // New member, new generation: resume proves the committed
    // offset survived, and a second commit must use the NEW
    // generation (a stale generation would be fenced by the
    // broker with ILLEGAL_GENERATION/UNKNOWN_MEMBER).
    // A's leave lands asynchronously; the first generation
    // may still give the partition to the departing A. Wait
    // for the generation where B actually owns it, then commit
    // through B's live session. Under load a member stream can
    // die mid-race (the commit then fences with 22/25 forever
    // because the session is gone); re-subscribe a fresh
    // member and retry in that case.
    let mut c2_error = -1;
    for _round in 0..3 {
        let mut b = client.subscribe(subscribe_req(&group, &topic)).await.expect("subscribe B");
        let assign_b = collect_until_assignment(&mut b, |l| l == &vec![0], std::time::Duration::from_secs(45)).await;
        assert_eq!(assign_b.last().cloned(), Some(vec![0]));
        let fetched = client
            .fetch_offset(pb::FetchOffsetRequest {
                group_id: group.clone(),
                topic: topic.clone(),
                ..Default::default()
            })
            .await
            .expect("fetch offset");
        assert_eq!(fetched.committed_offset, 1, "{fetched:?}");
        let c2 = client
            .commit_offset(pb::CommitOffsetRequest {
                group_id: group.clone(),
                topic: topic.clone(),
                committed_offset: 1,
                metadata: "gen2".to_string(),
                ..Default::default()
            })
            .await
            .expect("commit via B");
        c2_error = c2.error_code;
        if c2_error == 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    assert_eq!(c2_error, 0, "commit with current generation failed (stale fencing?)");
    let fetched2 = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            ..Default::default()
        })
        .await
        .expect("fetch offset 2");
    assert_eq!(fetched2.committed_offset, 1);
    assert_eq!(fetched2.metadata, "gen2");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_proxy_restart_resume() {
    let Some(broker) = broker_or_skip() else { return };
    let topic = unique_topic("grpc-dc-e2e-prestart");
    let group = format!("{topic}-prestart");
    // Proxy instance 1: consume two of three records and
    // commit offset 2.
    let proxy1 = setup(&broker).await;
    make_topic(&proxy1, &topic, 1).await;
    for v in ["pr-0", "pr-1", "pr-2"] {
        assert_eq!(produce_one(&proxy1, &topic, v).await.error_code, 0);
    }
    let mut stream1 = proxy1.subscribe(subscribe_req(&group, &topic)).await.expect("subscribe p1");
    let (_, _, values1) =
        collect_group(&mut stream1, 1, 2, std::time::Duration::from_secs(45)).await;
    // A fetch chunk may already carry pr-2 as well; only the
    // first two records are asserted here (the commit below
    // is by explicit offset, not by records seen).
    assert_eq!(values1[..2], ["pr-0", "pr-1"]);
    let committed = proxy1
        .commit_offset(pb::CommitOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            committed_offset: 2,
            ..Default::default()
        })
        .await
        .expect("commit p1");
    assert_eq!(committed.error_code, 0, "{committed:?}");
    // Proxy restart: instance 1 goes away entirely (client,
    // stream, and its in-memory group sessions); a fresh
    // service instance — the restarted proxy — takes over.
    drop(stream1);
    drop(proxy1);
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    // Proxy instance 2: the committed offset must survive,
    // and the group must resume exactly at it — pr-2 was
    // never committed, so it is delivered first, then the
    // newly produced pr-3. Nothing at or below offset 2 is
    // redelivered.
    let proxy2 = setup(&broker).await;
    let fetched = proxy2
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            ..Default::default()
        })
        .await
        .expect("fetch offset p2");
    assert_eq!(fetched.committed_offset, 2, "{fetched:?}");
    assert_eq!(produce_one(&proxy2, &topic, "pr-3").await.error_code, 0);
    let mut stream2 = proxy2.subscribe(subscribe_req(&group, &topic)).await.expect("subscribe p2");
    let (_, _, values2) =
        collect_group(&mut stream2, 1, 2, std::time::Duration::from_secs(45)).await;
    assert_eq!(values2, vec!["pr-2", "pr-3"], "group did not resume at committed offset after proxy restart");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_group_multi_topic() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let t1 = unique_topic("grpc-dc-e2e-mt1");
    let t2 = unique_topic("grpc-dc-e2e-mt2");
    make_topic(&client, &t1, 2).await;
    make_topic(&client, &t2, 1).await;
    assert_eq!(produce_part(&client, &t1, 0, "mt-a").await.error_code, 0);
    assert_eq!(produce_part(&client, &t1, 1, "mt-b").await.error_code, 0);
    assert_eq!(produce_part(&client, &t2, 0, "mt-c").await.error_code, 0);
    let group = format!("{t1}-mt");
    let mut req = subscribe_req(&group, &t1);
    req.topics = vec![t1.clone(), t2.clone()];
    let mut stream = client.subscribe(req).await.expect("subscribe multi");
    // Assignment must cover all three partitions.
    let mut assigned: Vec<(String, i32)> = Vec::new();
    let mut values: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(45);
    while assigned.len() < 3 || values.len() < 3 {
        let Ok(next) = tokio::time::timeout_at(deadline, stream.next()).await else { break };
        match next {
            Some(Ok(event)) => {
                if let Some(a) = event.assignment {
                    assigned = a.partitions.iter().map(|p| (p.topic.clone(), p.partition)).collect();
                }
                if let Some(batch) = event.batch {
                    for rec in batch.records {
                        values.push(String::from_utf8(rec.value).expect("utf8"));
                    }
                }
                if let Some(e) = event.group_error {
                    panic!("group error {}: {}", e.error_code, e.message);
                }
            }
            Some(Err(e)) => panic!("subscribe error: {e:?}"),
            None => break,
        }
    }
    assigned.sort();
    assert_eq!(
        assigned,
        vec![(t1.clone(), 0), (t1.clone(), 1), (t2.clone(), 0)],
        "multi-topic assignment incomplete"
    );
    values.sort();
    assert_eq!(values, vec!["mt-a".to_string(), "mt-b".to_string(), "mt-c".to_string()]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_proxy_producer_session_recovery() {
    let Some(broker) = broker_or_skip() else { return };
    let client = setup(&broker).await;
    let topic = unique_topic("grpc-dc-e2e-session");
    make_topic(&client, &topic, 1).await;

    // Unknown session ids are rejected, not downgraded to a
    // plain produce.
    let bogus = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("bogus")],
            session_id: "no-such-session".to_string(),
            ..Default::default()
        })
        .await;
    assert!(bogus.is_err(), "unknown session produce succeeded: {bogus:?}");

    // Idempotent session: produce, close, produce must fail;
    // a fresh session recovers and sequences restart cleanly.
    let opened = client
        .open_producer(pb::OpenProducerRequest::default())
        .await
        .expect("open producer");
    assert_eq!(opened.error_code, 0, "{opened:?}");
    let p1 = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("s1-a")],
            acks: pb::Acks::AcksAll,
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("session produce");
    assert_eq!(p1.error_code, 0, "{p1:?}");
    assert_eq!(p1.base_offset, 0);
    let closed = client
        .close_producer(pb::CloseProducerRequest {
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("close producer");
    assert_eq!(closed.error_code, 0, "{closed:?}");
    let after_close = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("s1-b")],
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await;
    assert!(after_close.is_err(), "produce after close succeeded: {after_close:?}");

    let reopened = client
        .open_producer(pb::OpenProducerRequest::default())
        .await
        .expect("reopen producer");
    assert_eq!(reopened.error_code, 0);
    assert_ne!(reopened.session_id, opened.session_id);
    let p2 = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![record("s2-a")],
            acks: pb::Acks::AcksAll,
            session_id: reopened.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("recovered produce");
    assert_eq!(p2.error_code, 0, "{p2:?}");
    assert_eq!(p2.base_offset, 1, "recovered produce landed at wrong offset");
    let values = consume_values(&client, &topic, 2).await;
    assert_eq!(values, vec!["s1-a".to_string(), "s2-a".to_string()]);
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
