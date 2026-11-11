//! Admin RPC coverage for the Rust Kafka proxy: the generated
//! gRPC admin operations (configs, partitions, delete-records,
//! groups, offsets, ACLs, transactions) against a real broker.
//!
//! Set KAFKA_PROXY_E2E_BROKER=host:port to run (Apache Kafka
//! or Redpanda). Without it the test is a no-op so plain
//! `cargo test` stays green on machines without a broker.

use kafka_native::client::KafkaConfig;
use kafka_native::{pb, stub};
use futures_util::StreamExt;
use grpc_dc::{loopback_pair, Channel, DcTransport, Server};
use kafka_native::service::KafkaService;
use std::sync::Arc;
use stub::{kafka_service, KafkaClient};

async fn setup(broker: &str) -> KafkaClient {
    let (a, b) = loopback_pair();
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker: broker.to_string(),
        client_id: "grpc-dc-kafka-admin-e2e".to_string(),
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn kafka_admin_e2e() {
    let Ok(broker) = std::env::var("KAFKA_PROXY_E2E_BROKER") else {
        eprintln!("KAFKA_PROXY_E2E_BROKER unset; skipping");
        return;
    };
    let client = setup(&broker).await;
    let topic = unique("grpcdc-admin");
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
        .expect("create topic");
    assert_eq!(created.results[0].error_code, 0, "{created:?}");

    // Configs: describe, alter, describe again, delete.
    let described = client
        .describe_configs(pb::DescribeConfigsRequest {
            resource_type: pb::ConfigResourceType::ConfigResourceTopic,
            resource_name: topic.clone(),
            config_keys: vec!["max.message.bytes".to_string()],
            ..Default::default()
        })
        .await
        .expect("describe configs");
    assert_eq!(described.error_code, 0, "{described:?}");
    assert!(described.values.iter().any(|v| v.name == "max.message.bytes"));

    let altered = client
        .alter_configs(pb::AlterConfigsRequest {
            resource_type: pb::ConfigResourceType::ConfigResourceTopic,
            resource_name: topic.clone(),
            entries: vec![pb::AlterConfigEntry {
                name: "max.message.bytes".to_string(),
                value: "12345".to_string(),
                op: pb::ConfigOp::ConfigOpSet,
                ..Default::default()
            }],
            ..Default::default()
        })
        .await
        .expect("alter configs");
    assert_eq!(altered.error_code, 0, "{altered:?}");
    // The alter is applied through the broker's metadata log;
    // poll until the new value is visible instead of assuming
    // the first describe already sees it.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let redescribed = loop {
        let described = client
            .describe_configs(pb::DescribeConfigsRequest {
                resource_type: pb::ConfigResourceType::ConfigResourceTopic,
                resource_name: topic.clone(),
                config_keys: vec!["max.message.bytes".to_string()],
                ..Default::default()
            })
            .await
            .expect("redescribe configs");
        if described.values.iter().find(|v| v.name == "max.message.bytes").map(|v| v.value.as_str()) == Some("12345") {
            break described;
        }
        assert!(std::time::Instant::now() < deadline, "altered config never visible: {described:?}");
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    };
    assert_eq!(
        redescribed.values.iter().find(|v| v.name == "max.message.bytes").map(|v| v.value.as_str()),
        Some("12345"),
        "{redescribed:?}"
    );

    // Partitions: grow 1 -> 2, then a shrink must fail.
    let grown = client
        .create_partitions(pb::CreatePartitionsRequest {
            topic: topic.clone(),
            total_count: 2,
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("create partitions");
    assert_eq!(grown.error_code, 0, "{grown:?}");
    let shrunk = client
        .create_partitions(pb::CreatePartitionsRequest {
            topic: topic.clone(),
            total_count: 1,
            timeout_ms: 30_000,
            ..Default::default()
        })
        .await
        .expect("create partitions shrink");
    assert_ne!(shrunk.error_code, 0, "shrinking partitions must fail");

    // Produce two records, then delete-records to the watermark.
    let produced = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![pb::Record {
                key: b"k".to_vec(),
                value: b"v".to_vec(),
                ..Default::default()
            }],
            acks: pb::Acks::AcksAll,
            ..Default::default()
        })
        .await
        .expect("produce");
    assert_eq!(produced.error_code, 0, "{produced:?}");
    let deleted = client
        .delete_records(pb::DeleteRecordsRequest {
            topic: topic.clone(),
            partition: 0,
            before_offset: -1,
            ..Default::default()
        })
        .await
        .expect("delete records");
    assert_eq!(deleted.error_code, 0, "{deleted:?}");
    assert_eq!(deleted.low_watermark, produced.base_offset + 1, "{deleted:?}");

    // Groups: subscribe a member, list/describe it, delete its
    // offsets, leave, and delete the group.
    let group = unique("grpcdc-admin-group");
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
    let mut saw_assignment = false;
    while let Some(item) = sub.next().await {
        let resp = item.expect("subscribe response");
        if resp.group_error.is_some() {
            break;
        }
        if resp.assignment.map(|a| !a.partitions.is_empty()).unwrap_or(false) {
            saw_assignment = true;
            break;
        }
    }
    assert!(saw_assignment, "no assignment from Subscribe");

    let listed = client
        .list_groups(pb::ListGroupsRequest::default())
        .await
        .expect("list groups");
    assert_eq!(listed.error_code, 0, "{listed:?}");
    assert!(listed.groups.iter().any(|g| g.group_id == group), "{listed:?}");

    let described_groups = client
        .describe_groups(pb::DescribeGroupsRequest { group_ids: vec![group.clone()], ..Default::default() })
        .await
        .expect("describe groups");
    assert_eq!(described_groups.groups.len(), 1);
    assert_eq!(described_groups.groups[0].error_code, 0, "{described_groups:?}");
    assert!(!described_groups.groups[0].members.is_empty(), "{described_groups:?}");

    // Kafka deletes committed offsets only for an empty group,
    // so the subscribed member leaves before the commit/delete
    // legs (committing to an empty group is fine). Wait for the
    // leave to land instead of sleeping a fixed delay.
    drop(sub);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    loop {
        let described = client
            .describe_groups(pb::DescribeGroupsRequest { group_ids: vec![group.clone()], ..Default::default() })
            .await
            .expect("describe groups while leaving");
        if described.groups[0].members.is_empty() {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "member never left: {described:?}");
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    }

    // Commit, then delete the committed offset.
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
    assert_eq!(committed.error_code, 0, "{committed:?}");
    let offset_deleted = client
        .delete_group_offsets(pb::DeleteGroupOffsetsRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            partitions: vec![0],
            ..Default::default()
        })
        .await
        .expect("delete group offsets");
    assert_eq!(offset_deleted.error_code, 0, "{offset_deleted:?}");
    let fetched = client
        .fetch_offset(pb::FetchOffsetRequest {
            group_id: group.clone(),
            topic: topic.clone(),
            partition: 0,
            ..Default::default()
        })
        .await
        .expect("fetch offset");
    assert_eq!(fetched.committed_offset, -1, "offset must be gone: {fetched:?}");

    // Transactions: open a transactional producer and see it listed.
    let txid = unique("grpcdc-admin-tx");
    let opened = client
        .open_producer(pb::OpenProducerRequest { transactional_id: txid.clone(), ..Default::default() })
        .await
        .expect("open producer");
    assert_eq!(opened.error_code, 0, "{opened:?}");
    // Brokers only list transactions with activity: produce one
    // record so the transaction is ongoing when listed.
    let tx_produced = client
        .produce(pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![pb::Record {
                key: b"txk".to_vec(),
                value: b"txv".to_vec(),
                ..Default::default()
            }],
            acks: pb::Acks::AcksAll,
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await
        .expect("txn produce");
    assert_eq!(tx_produced.error_code, 0, "{tx_produced:?}");
    let tx_listed = client
        .list_transactions(pb::ListTransactionsRequest::default())
        .await
        .expect("list transactions");
    assert_eq!(tx_listed.error_code, 0, "{tx_listed:?}");
    assert!(
        tx_listed.transactions.iter().any(|t| t.transactional_id == txid),
        "{tx_listed:?}"
    );
    let tx_described = client
        .describe_transactions(pb::DescribeTransactionsRequest {
            transactional_ids: vec![txid.clone()],
            ..Default::default()
        })
        .await
        .expect("describe transactions");
    assert_eq!(tx_described.transactions.len(), 1);
    assert_eq!(tx_described.transactions[0].producer_id, opened.producer_id, "{tx_described:?}");
    let _ = client
        .close_producer(pb::CloseProducerRequest {
            session_id: opened.session_id.clone(),
            ..Default::default()
        })
        .await;

    // ACLs: create one, describe it, delete it.
    let acl = pb::Acl {
        resource_type: 2, // TOPIC
        resource_name: topic.clone(),
        pattern_type: 1, // LITERAL
        principal: "User:grpcdc-admin-test".to_string(),
        host: "*".to_string(),
        operation: 4, // READ
        permission_type: 3, // ALLOW
        ..Default::default()
    };
    let acl_created = client
        .create_acls(pb::CreateAclsRequest { acls: vec![acl.clone()], ..Default::default() })
        .await
        .expect("create acls");
    // A broker with no authorizer configured answers
    // SECURITY_DISABLED (54); strict allow/deny coverage runs
    // against the authorizer fixture in scripts/kafka-e2e.sh.
    assert!(
        acl_created.error_codes == vec![0] || acl_created.error_codes == vec![54],
        "{acl_created:?}"
    );
    let acl_described = client
        .describe_acls(pb::DescribeAclsRequest {
            filter: Some(Box::new(pb::Acl {
                resource_type: 2,
                resource_name: topic.clone(),
                pattern_type: 1,
                principal: "User:grpcdc-admin-test".to_string(),
                operation: 1,       // ANY
                permission_type: 1, // ANY
                ..Default::default()
            })),
            ..Default::default()
        })
        .await
        .expect("describe acls");
    // Plaintext test brokers may disable ACL storage; accept a
    // broker-side error but require the created ACL to be
    // visible when describe works.
    if acl_described.error_code == 0 {
        assert!(
            acl_described.acls.iter().any(|a| a.principal == "User:grpcdc-admin-test"),
            "{acl_described:?}"
        );
    }
    let acl_deleted = client
        .delete_acls(pb::DeleteAclsRequest { filters: vec![acl], ..Default::default() })
        .await
        .expect("delete acls");
    assert_eq!(acl_deleted.error_codes.len(), 1);

    // The subscribed member already left above (before the
    // offset-delete leg), so the group is empty and deletable.
    let group_deleted = client
        .delete_groups(pb::DeleteGroupsRequest { group_ids: vec![group], ..Default::default() })
        .await
        .expect("delete groups");
    assert_eq!(group_deleted.results.len(), 1);
    assert_eq!(group_deleted.results[0].error_code, 0, "{group_deleted:?}");

    let topic_deleted = client
        .delete_topics(pb::DeleteTopicsRequest { topics: vec![topic], timeout_ms: 30_000, ..Default::default() })
        .await
        .expect("delete topic");
    assert_eq!(topic_deleted.results[0].error_code, 0, "{topic_deleted:?}");
}
