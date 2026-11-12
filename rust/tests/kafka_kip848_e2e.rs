//! KIP-848 next-gen consumer protocol coverage: group
//! membership over ConsumerGroupHeartbeat (API 68) when the
//! broker supports it, with the classic protocol as fallback.
//!
//! Set KAFKA_PROXY_E2E_BROKER=host:port to run (Apache Kafka
//! or Redpanda). Without it the test is a no-op so plain
//! `cargo test` stays green on machines without a broker.
//! Protocol-specific assertions engage only when the broker
//! actually runs the joining heartbeat (probed with a
//! throwaway group first), so the suite stays green against
//! classic-only brokers.

use futures_util::StreamExt;
use kafka_native::client::{KafkaConfig, API_CONSUMER_GROUP_HEARTBEAT};
use kafka_native::service::KafkaService;
use kafka_native::{pb, stub, Broker};
use grpc_dc::{loopback_pair, Channel, DcTransport, Server};
use std::sync::Arc;
use stub::{kafka_service, KafkaClient};

async fn setup(broker: &str) -> KafkaClient {
    let (a, b) = loopback_pair();
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: broker.to_string(),
        client_id: "grpc-dc-kafka-kip848-e2e".to_string(),
        sasl: None,
        tls: None,
    }));
    let server_transport: Arc<dyn DcTransport> = Arc::new(b);
    tokio::spawn(Server::serve(server_transport, vec![kafka_service(service)]));
    let client_transport: Arc<dyn DcTransport> = Arc::new(a);
    KafkaClient::new(Channel::new(client_transport))
}

fn broker_direct(broker: &str) -> Arc<Broker> {
    Arc::new(Broker::new(KafkaConfig {
        broker: broker.to_string(),
        client_id: "grpc-dc-kafka-kip848-e2e".to_string(),
        sasl: None,
        tls: None,
    }))
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

fn broker_or_skip() -> Option<String> {
    match std::env::var("KAFKA_PROXY_E2E_BROKER") {
        Ok(b) => Some(b),
        Err(_) => {
            eprintln!("KAFKA_PROXY_E2E_BROKER unset: skipping");
            None
        }
    }
}

/// Does this broker run KIP-848 groups? Probe: advertise
/// check, then a throwaway-group joining heartbeat (epoch -1
/// cleanup). True only when the heartbeat is accepted.
async fn broker_runs_848(broker: &Arc<Broker>, probe_group: &str) -> bool {
    let Ok(coord) = broker.coordinator_fresh(probe_group, 0).await else {
        return false;
    };
    if !coord.lock().await.has_api(API_CONSUMER_GROUP_HEARTBEAT) {
        return false;
    }
    // Retry through coordinator loading (14/15/16), like the
    // subscribe loop does.
    let mut beat = None;
    for _ in 0..20 {
        match broker
            .consumer_heartbeat(&coord, probe_group, "", 0, None, 60_000, &[], &[])
            .await
        {
            Ok(b) if matches!(b.error_code, 14 | 15 | 16) => {
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            }
            Ok(b) => {
                beat = Some(b);
                break;
            }
            Err(_) => return false,
        }
    }
    let Some(beat) = beat else { return false };
    if beat.error_code != 0 || beat.member_id.is_empty() {
        return false;
    }
    let _ = broker
        .consumer_heartbeat(
            &coord,
            probe_group,
            &beat.member_id,
            -1,
            None,
            60_000,
            &[],
            &[],
        )
        .await;
    let _ = broker.delete_groups(&[probe_group.to_string()]).await;
    true
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
        .expect("create topics");
    assert_eq!(created.results[0].error_code, 0, "create failed: {created:?}");
    // Wait until every partition has a leader before producing.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let meta = client
            .metadata(pb::MetadataRequest {
                topics: vec![topic.to_string()],
                ..Default::default()
            })
            .await
            .expect("metadata");
        let ready = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .map(|t| {
                t.partitions.len() == partitions as usize
                    && t.partitions.iter().all(|p| p.leader_id >= 0)
            })
            .unwrap_or(false);
        if ready {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "topic never ready: {meta:?}");
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
}

async fn next_assignment<S>(stream: &mut S) -> Option<pb::Assignment>
where
    S: futures_util::Stream<Item = Result<pb::GroupSubscribeResponse, grpc_dc::Status>> + Unpin,
{
    while let Some(item) = stream.next().await {
        let resp = item.expect("subscribe response");
        if let Some(err) = resp.group_error {
            panic!("group error {}: {}", err.error_code, err.message);
        }
        if let Some(assignment) = resp.assignment {
            if !assignment.partitions.is_empty() {
                return Some(*assignment);
            }
        }
    }
    None
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_kip848_group_lifecycle() {
    let Some(broker_addr) = broker_or_skip() else { return };
    let client = setup(&broker_addr).await;
    let broker = broker_direct(&broker_addr);
    let runs_848 = broker_runs_848(&broker, &unique("grpcdc-848-probe")).await;

    let topic = unique("grpcdc-848-topic");
    make_topic(&client, &topic, 3).await;
    for partition in 0..3 {
        // Leaders can be visible in metadata slightly before
        // the partition accepts produce (error 3); retry like
        // a real client would.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        let produced = loop {
            let produced = client
                .produce(pb::ProduceRequest {
                    topic: topic.clone(),
                    partition,
                    records: vec![record("a"), record("b")],
                    acks: pb::Acks::AcksAll,
                    ..Default::default()
                })
                .await
                .expect("produce");
            if produced.error_code != 3 || std::time::Instant::now() >= deadline {
                break produced;
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        };
        assert_eq!(produced.error_code, 0, "produce failed: {produced:?}");
    }

    let group = unique("grpcdc-848-group");
    let mut sub = client
        .subscribe(pb::GroupSubscribeRequest {
            group_id: group.clone(),
            topics: vec![topic.clone()],
            session_timeout_ms: 30_000,
            max_poll_records: 10,
            auto_offset_reset: "earliest".to_string(),
            ..Default::default()
        })
        .await
        .expect("subscribe stream");
    let assignment = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        next_assignment(&mut sub),
    )
    .await
    .expect("assignment timed out")
    .expect("no assignment");
    let mut partitions: Vec<i32> =
        assignment.partitions.iter().map(|p| p.partition).collect();
    partitions.sort_unstable();
    assert_eq!(partitions, vec![0, 1, 2], "assignment: {assignment:?}");

    // Consume all six records through the subscription.
    let mut values = Vec::new();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while values.len() < 6 {
        assert!(std::time::Instant::now() < deadline, "records missing: {values:?}");
        let item = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            sub.next(),
        )
        .await
        .expect("batch timed out")
        .expect("subscribe stream ended")
        .expect("subscribe response");
        if let Some(batch) = item.batch {
            for rec in batch.records {
                values.push(String::from_utf8(rec.value).expect("utf8"));
            }
        }
    }
    values.sort();
    assert_eq!(values, vec!["a", "a", "a", "b", "b", "b"]);

    // Commit through the live session, read it back.
    let committed = client
        .commit_offset(pb::CommitOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            partition: 0,
            committed_offset: 1,
            ..Default::default()
        })
        .await
        .expect("commit offset");
    assert_eq!(committed.error_code, 0, "commit failed: {committed:?}");
    let fetched = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            partition: 0,
            ..Default::default()
        })
        .await
        .expect("fetch offset");
    assert_eq!(fetched.error_code, 0, "fetch offset failed: {fetched:?}");
    assert_eq!(fetched.committed_offset, 1);

    // Describe while subscribed: one member holding all three
    // partitions (via classic DescribeGroups, or the
    // ConsumerGroupDescribe fallback for KIP-848 groups).
    let described = client
        .describe_groups(pb::DescribeGroupsRequest {
            group_ids: vec![group.clone()],
            ..Default::default()
        })
        .await
        .expect("describe groups");
    assert_eq!(described.groups.len(), 1);
    let g = &described.groups[0];
    assert_eq!(g.error_code, 0, "describe failed: {g:?}");
    assert_eq!(g.protocol_type, "consumer", "{g:?}");
    assert_eq!(g.members.len(), 1, "{g:?}");
    let mut member_partitions: Vec<i32> =
        g.members[0].assignment.iter().map(|p| p.partition).collect();
    member_partitions.sort_unstable();
    assert_eq!(member_partitions, vec![0, 1, 2], "{g:?}");

    if runs_848 {
        // Ground truth: a classic JoinGroup against a live
        // KIP-848 group must be refused (the group does not
        // exist under the classic protocol).
        let coord = broker
            .coordinator_fresh(&group, 0)
            .await
            .expect("coordinator");
        let subscription = kafka_native::client::encode_subscription(&[topic.clone()]);
        let join = broker
            .join_group(
                &coord,
                &group,
                "",
                None,
                30_000,
                60_000,
                vec![("range".to_string(), subscription)],
            )
            .await
            .expect("classic join probe");
        assert_ne!(
            join.error_code, 0,
            "classic JoinGroup unexpectedly joined a KIP-848 group"
        );
    }

    // Leave, then the group reads empty and can be deleted.
    drop(sub);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    loop {
        let described = client
            .describe_groups(pb::DescribeGroupsRequest {
                group_ids: vec![group.clone()],
                ..Default::default()
            })
            .await
            .expect("describe while leaving");
        if described.groups[0].members.is_empty() {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "member never left: {described:?}");
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }
    let deleted = client
        .delete_groups(pb::DeleteGroupsRequest {
            group_ids: vec![group.clone()],
            ..Default::default()
        })
        .await
        .expect("delete groups");
    assert_eq!(deleted.results[0].error_code, 0, "delete failed: {deleted:?}");

    let deleted_topic = client
        .delete_topics(pb::DeleteTopicsRequest {
            topics: vec![topic.clone()],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("delete topics");
    assert_eq!(deleted_topic.results[0].error_code, 0, "{deleted_topic:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_kip848_two_member_rebalance() {
    let Some(broker_addr) = broker_or_skip() else { return };
    let client = setup(&broker_addr).await;
    let broker = broker_direct(&broker_addr);
    if !broker_runs_848(&broker, &unique("grpcdc-848-probe")).await {
        eprintln!("broker does not run KIP-848: skipping rebalance assertions");
        return;
    }

    let topic = unique("grpcdc-848-rebal-topic");
    make_topic(&client, &topic, 4).await;
    let group = unique("grpcdc-848-rebal-group");
    let subscribe = |group: &str, topic: &str| pb::GroupSubscribeRequest {
        group_id: group.to_string(),
        topics: vec![topic.to_string()],
        session_timeout_ms: 30_000,
        max_poll_records: 10,
        auto_offset_reset: "earliest".to_string(),
        ..Default::default()
    };

    let mut sub_a = client
        .subscribe(subscribe(&group, &topic))
        .await
        .expect("subscribe a");
    let first = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        next_assignment(&mut sub_a),
    )
    .await
    .expect("a assignment timed out")
    .expect("a no assignment");
    assert_eq!(first.partitions.len(), 4, "first member: {first:?}");

    let mut sub_b = client
        .subscribe(subscribe(&group, &topic))
        .await
        .expect("subscribe b");
    let b_assignment = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        next_assignment(&mut sub_b),
    )
    .await
    .expect("b assignment timed out")
    .expect("b no assignment");
    assert!(!b_assignment.partitions.is_empty(), "b got nothing: {b_assignment:?}");

    // A must observe the rebalance (its assignment shrinks) and
    // the two members' partitions stay disjoint, covering all.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut a_partitions: Vec<i32> =
        first.partitions.iter().map(|p| p.partition).collect();
    while a_partitions.len() == 4 {
        assert!(std::time::Instant::now() < deadline, "a never rebalanced");
        let item = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            sub_a.next(),
        )
        .await
        .expect("a rebalance timed out")
        .expect("a stream ended")
        .expect("a response");
        if let Some(assignment) = item.assignment {
            a_partitions = assignment.partitions.iter().map(|p| p.partition).collect();
        }
    }
    let b_partitions: Vec<i32> =
        b_assignment.partitions.iter().map(|p| p.partition).collect();
    let mut union = a_partitions.clone();
    union.extend(b_partitions.iter().copied());
    union.sort_unstable();
    assert_eq!(union, vec![0, 1, 2, 3], "a={a_partitions:?} b={b_partitions:?}");
    let overlap = a_partitions.iter().filter(|p| b_partitions.contains(p)).count();
    assert_eq!(overlap, 0, "a={a_partitions:?} b={b_partitions:?}");

    // After A leaves, B inherits every partition.
    drop(sub_a);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut b_now = b_partitions.clone();
    while b_now.len() < 4 {
        assert!(std::time::Instant::now() < deadline, "b never inherited: {b_now:?}");
        let item = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            sub_b.next(),
        )
        .await
        .expect("b inherit timed out")
        .expect("b stream ended")
        .expect("b response");
        if let Some(assignment) = item.assignment {
            if !assignment.partitions.is_empty() {
                b_now = assignment.partitions.iter().map(|p| p.partition).collect();
            }
        }
    }
    b_now.sort_unstable();
    assert_eq!(b_now, vec![0, 1, 2, 3]);

    drop(sub_b);
    let _ = client
        .delete_groups(pb::DeleteGroupsRequest {
            group_ids: vec![group.clone()],
            ..Default::default()
        })
        .await;
    let _ = client
        .delete_topics(pb::DeleteTopicsRequest {
            topics: vec![topic.clone()],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_kip848_static_membership() {
    let Some(broker_addr) = broker_or_skip() else { return };
    let client = setup(&broker_addr).await;
    let broker = broker_direct(&broker_addr);
    if !broker_runs_848(&broker, &unique("grpcdc-848-probe")).await {
        eprintln!("broker does not run KIP-848: skipping static assertions");
        return;
    }

    let topic = unique("grpcdc-848-static-topic");
    make_topic(&client, &topic, 1).await;
    let group = unique("grpcdc-848-static-group");
    let subscribe = || pb::GroupSubscribeRequest {
        group_id: group.clone(),
        topics: vec![topic.clone()],
        group_instance_id: "static-member-1".to_string(),
        group_protocol: "consumer".to_string(),
        session_timeout_ms: 30_000,
        max_poll_records: 10,
        auto_offset_reset: "earliest".to_string(),
        ..Default::default()
    };

    let mut s1 = client.subscribe(subscribe()).await.expect("subscribe static 1");
    let a1 = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        next_assignment(&mut s1),
    )
    .await
    .expect("static assignment timed out")
    .expect("static no assignment");
    assert_eq!(a1.partitions.len(), 1, "{a1:?}");
    let member_1 = a1.member_id.clone();
    assert!(!member_1.is_empty());
    drop(s1);
    // Brief settle so the leave lands before the rejoin.
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;

    let mut s2 = client.subscribe(subscribe()).await.expect("subscribe static 2");
    let a2 = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        next_assignment(&mut s2),
    )
    .await
    .expect("static rejoin timed out")
    .expect("static rejoin no assignment");
    assert_eq!(a2.partitions.len(), 1, "static member rejoins with its partition: {a2:?}");

    // Fencing: a second live subscribe with the same instance
    // id fences the first member; its stream must error or end
    // (it must NOT silently rejoin and fence the new member).
    let mut s3 = client.subscribe(subscribe()).await.expect("subscribe static 3");
    let a3 = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        next_assignment(&mut s3),
    )
    .await
    .expect("static fencing assignment timed out")
    .expect("static fencing no assignment");
    assert_eq!(a3.partitions.len(), 1, "{a3:?}");
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

    drop(s3);
    let _ = client
        .delete_groups(pb::DeleteGroupsRequest {
            group_ids: vec![group.clone()],
            ..Default::default()
        })
        .await;
    let _ = client
        .delete_topics(pb::DeleteTopicsRequest {
            topics: vec![topic.clone()],
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await;
}

