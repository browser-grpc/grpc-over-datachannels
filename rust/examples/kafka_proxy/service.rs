//! gRPC service implementation: maps the generated Kafka
//! service onto the Kafka protocol client. The proxy holds
//! producer sessions (idempotence/transactions) and consumer
//! group memberships on behalf of clients.

use crate::client::{
    decode_assignment, decode_subscription, encode_assignment, encode_subscription, Broker,
    KafkaConfig,
};
use grpc_dc::{CallCtx, ResponseStream, Status};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

pub struct ProducerSession {
    pub producer_id: i64,
    pub producer_epoch: i16,
    pub transactional_id: String,
    pub sequences: Mutex<HashMap<(String, i32), i32>>,
    pub txn_partitions: Mutex<HashSet<(String, i32)>>,
    pub txn_groups: Mutex<HashSet<String>>,
    pub txn_offsets: Mutex<HashMap<(String, String, i32), (i64, String)>>,
}

#[derive(Clone)]
pub struct GroupSession {
    pub generation_id: i32,
    pub member_id: String,
    pub group_instance_id: Option<String>,
}

pub struct KafkaService {
    pub broker: Arc<Broker>,
    pub sessions: Mutex<HashMap<String, Arc<ProducerSession>>>,
    pub groups: Arc<Mutex<HashMap<String, GroupSession>>>,
    session_counter: AtomicU64,
    round_robin: AtomicI32,
}

impl KafkaService {
    pub fn new(cfg: KafkaConfig) -> KafkaService {
        KafkaService {
            broker: Arc::new(Broker::new(cfg)),
            sessions: Mutex::new(HashMap::new()),
            groups: Arc::new(Mutex::new(HashMap::new())),
            session_counter: AtomicU64::new(0),
            round_robin: AtomicI32::new(0),
        }
    }

    async fn resolve_partition(&self, topic: &str, partition: i32) -> Result<i32, Status> {
        if partition >= 0 {
            return Ok(partition);
        }
        let meta = self.broker.metadata(vec![topic.to_string()], false).await?;
        for t in &meta.topics {
            if t.name == topic && !t.partitions.is_empty() {
                let n = t.partitions.len() as i32;
                let pick = self.round_robin.fetch_add(1, Ordering::Relaxed).rem_euclid(n);
                return Ok(pick);
            }
        }
        Ok(0)
    }
}

fn codec_of(c: crate::pb::Compression) -> u8 {
    match c {
        crate::pb::Compression::CompressionGzip => 1,
        crate::pb::Compression::CompressionSnappy => 2,
        crate::pb::Compression::CompressionLz4 => 3,
        crate::pb::Compression::CompressionZstd => 4,
        _ => 0,
    }
}

fn acks_of(a: crate::pb::Acks) -> i16 {
    match a {
        crate::pb::Acks::AcksNone => 0,
        crate::pb::Acks::AcksLeader => 1,
        _ => -1,
    }
}

#[grpc_dc::async_trait]
impl crate::stub::Kafka for KafkaService {
    async fn metadata(
        &self,
        req: crate::pb::MetadataRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::MetadataResponse, Status> {
        self.broker.metadata(req.topics.clone(), req.allow_auto_topic_creation).await
    }

    async fn open_producer(
        &self,
        req: crate::pb::OpenProducerRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::OpenProducerResponse, Status> {
        let tid = if req.transactional_id.is_empty() { None } else { Some(req.transactional_id.as_str()) };
        let timeout = if req.transaction_timeout_ms > 0 { req.transaction_timeout_ms } else { 60_000 };
        let (pid, epoch, err) = self.broker.init_producer_id(tid, timeout).await?;
        let mut out = crate::pb::OpenProducerResponse {
            producer_id: pid,
            producer_epoch: epoch as i32,
            error_code: err,
            ..Default::default()
        };
        if err == 0 {
            let id = format!(
                "sess-{}-{}",
                pid,
                self.session_counter.fetch_add(1, Ordering::Relaxed)
            );
            out.session_id = id.clone();
            self.sessions.lock().await.insert(
                id,
                Arc::new(ProducerSession {
                    producer_id: pid,
                    producer_epoch: epoch,
                    transactional_id: req.transactional_id.clone(),
                    sequences: Mutex::new(HashMap::new()),
                    txn_partitions: Mutex::new(HashSet::new()),
                    txn_groups: Mutex::new(HashSet::new()),
                    txn_offsets: Mutex::new(HashMap::new()),
                }),
            );
        }
        Ok(out)
    }

    async fn close_producer(
        &self,
        req: crate::pb::CloseProducerRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::CloseProducerResponse, Status> {
        if let Some(session) = self.sessions.lock().await.remove(&req.session_id) {
            if !session.transactional_id.is_empty() {
                let _ = self
                    .broker
                    .end_txn(&session.transactional_id, session.producer_id, session.producer_epoch, false)
                    .await;
            }
        }
        Ok(crate::pb::CloseProducerResponse::default())
    }

    async fn end_transaction(
        &self,
        req: crate::pb::EndTransactionRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::EndTransactionResponse, Status> {
        let session = self
            .sessions
            .lock()
            .await
            .get(&req.session_id)
            .cloned()
            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown producer session"))?;
        if session.transactional_id.is_empty() {
            return Ok(crate::pb::EndTransactionResponse { error_code: -1, ..Default::default() });
        }
        // Offsets staged through CommitOffset(session_id) are
        // attached to this transaction first (AddOffsetsToTxn per
        // group, then TxnOffsetCommit per partition) so they
        // commit or abort atomically with the records.
        if req.commit {
            let offsets = session.txn_offsets.lock().await.clone();
            if !offsets.is_empty() {
                let mut groups: Vec<String> = Vec::new();
                for (group, _, _) in offsets.keys() {
                    if !groups.contains(group) {
                        groups.push(group.clone());
                    }
                }
                for group in &groups {
                    let err = self
                        .broker
                        .add_offsets_to_txn(
                            &session.transactional_id,
                            group,
                            session.producer_id,
                            session.producer_epoch,
                        )
                        .await?;
                    if err != 0 {
                        return Ok(crate::pb::EndTransactionResponse {
                            error_code: err,
                            ..Default::default()
                        });
                    }
                }
                for ((group, topic, partition), (offset, metadata)) in &offsets {
                    let err = self
                        .broker
                        .txn_offset_commit(
                            &session.transactional_id,
                            group,
                            session.producer_id,
                            session.producer_epoch,
                            topic,
                            *partition,
                            *offset,
                            metadata,
                        )
                        .await?;
                    if err != 0 {
                        return Ok(crate::pb::EndTransactionResponse {
                            error_code: err,
                            ..Default::default()
                        });
                    }
                }
            }
        }
        let err = self
            .broker
            .end_txn(&session.transactional_id, session.producer_id, session.producer_epoch, req.commit)
            .await?;
        if err == 0 {
            // Append the COMMIT/ABORT control batch to every
            // partition this transaction wrote: some brokers
            // (Redpanda) resolve the transaction in the
            // coordinator without writing log markers, and
            // without a marker read_committed cannot distinguish
            // aborted data from committed data.
            let partitions: Vec<(String, i32)> = session
                .txn_partitions
                .lock()
                .await
                .iter()
                .cloned()
                .collect();
            if !partitions.is_empty() {
                let _ = self
                    .broker
                    .write_txn_markers(
                        &partitions,
                        session.producer_id,
                        session.producer_epoch,
                        req.commit,
                        &session.transactional_id,
                    )
                    .await;
            }
        }
        if err == 0 {
            session.txn_partitions.lock().await.clear();
            session.txn_groups.lock().await.clear();
            session.txn_offsets.lock().await.clear();
        }
        Ok(crate::pb::EndTransactionResponse { error_code: err, ..Default::default() })
    }

    async fn produce(
        &self,
        req: crate::pb::ProduceRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::ProduceResponse, Status> {
        let partition = self.resolve_partition(&req.topic, req.partition).await?;
        let session = if req.session_id.is_empty() {
            None
        } else {
            Some(
                self.sessions
                    .lock()
                    .await
                    .get(&req.session_id)
                    .cloned()
                    .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown producer session"))?,
            )
        };
        let (producer_id, producer_epoch, base_sequence, transactional_id) = match &session {
            Some(s) => {
                if !s.transactional_id.is_empty() {
                    let key = (req.topic.clone(), partition);
                    let mut parts = s.txn_partitions.lock().await;
                    if !parts.contains(&key) {
                        let results = self
                            .broker
                            .add_partitions_to_txn(
                                &s.transactional_id,
                                s.producer_id,
                                s.producer_epoch,
                                vec![(req.topic.clone(), vec![partition])],
                            )
                            .await?;
                        if let Some((_, _, err)) = results.first() {
                            if *err != 0 {
                                return Ok(crate::pb::ProduceResponse {
                                    partition,
                                    error_code: *err,
                                    ..Default::default()
                                });
                            }
                        }
                        parts.insert(key);
                    }
                }
                let seq = {
                    let seqs = s.sequences.lock().await;
                    *seqs.get(&(req.topic.clone(), partition)).unwrap_or(&0)
                };
                (
                    s.producer_id,
                    s.producer_epoch,
                    seq,
                    if s.transactional_id.is_empty() {
                        None
                    } else {
                        Some(s.transactional_id.clone())
                    },
                )
            }
            None => (-1, -1, -1, None),
        };
        let timeout = if req.timeout_ms > 0 { req.timeout_ms } else { 30_000 };
        let outcome = self
            .broker
            .produce(
                &req.topic,
                partition,
                &req.records,
                acks_of(req.acks),
                timeout,
                codec_of(req.compression),
                producer_id,
                producer_epoch,
                base_sequence,
                transactional_id.as_deref(),
            )
            .await?;
        if outcome.error_code == 0 {
            if let Some(s) = &session {
                let mut seqs = s.sequences.lock().await;
                let entry = seqs.entry((req.topic.clone(), partition)).or_insert(0);
                *entry += req.records.len() as i32;
            }
        }
        Ok(crate::pb::ProduceResponse {
            partition: outcome.partition,
            base_offset: outcome.base_offset,
            log_append_time_ms: outcome.log_append_time_ms,
            error_code: outcome.error_code,
            ..Default::default()
        })
    }

    async fn consume(
        &self,
        req: crate::pb::ConsumeRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<crate::pb::ConsumeResponse>, Status> {
        let broker = self.broker.clone();
        let max_records = if req.max_records > 0 { req.max_records as usize } else { 500 };
        let max_wait = if req.max_wait_ms > 0 { req.max_wait_ms } else { 500 };
        struct State {
            broker: Arc<Broker>,
            req: crate::pb::ConsumeRequest,
            offset: Option<i64>,
            max_records: usize,
            max_wait: i32,
            done: bool,
        }
        let stream = futures_util::stream::unfold(
            State { broker, req, offset: None, max_records, max_wait, done: false },
            |mut st| async move {
                if st.done {
                    return None;
                }
                // Resolve the start offset once.
                if st.offset.is_none() {
                    let start = if st.req.offset >= 0 {
                        st.req.offset
                    } else {
                        match st
                            .broker
                            .list_offsets(
                                &st.req.topic,
                                st.req.partition,
                                st.req.offset,
                                st.req.read_committed,
                            )
                            .await
                        {
                            Ok((off, _, err)) => {
                                if err != 0 {
                                    st.done = true;
                                    return Some((
                                        Ok(crate::pb::ConsumeResponse {
                                            topic: st.req.topic.clone(),
                                            partition: st.req.partition,
                                            error_code: err,
                                            ..Default::default()
                                        }),
                                        st,
                                    ));
                                }
                                off
                            }
                            Err(e) => {
                                st.done = true;
                                return Some((Err(e), st));
                            }
                        }
                    };
                    st.offset = Some(start);
                }
                loop {
                    let offset = st.offset.unwrap();
                    match st
                        .broker
                        .fetch(
                            &st.req.topic,
                            st.req.partition,
                            offset,
                            st.max_wait,
                            1,
                            4 * 1024 * 1024,
                            st.req.read_committed,
                        )
                        .await
                    {
                        Ok(outcome) => {
                            if outcome.error_code != 0 {
                                st.done = true;
                                return Some((
                                    Ok(crate::pb::ConsumeResponse {
                                        topic: st.req.topic.clone(),
                                        partition: st.req.partition,
                                        high_watermark: outcome.high_watermark,
                                        error_code: outcome.error_code,
                                        ..Default::default()
                                    }),
                                    st,
                                ));
                            }
                            if outcome.records.is_empty() {
                                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                                continue;
                            }
                            let mut records = outcome.records;
                            if records.len() > st.max_records {
                                records.truncate(st.max_records);
                            }
                            if let Some(last) = records.last() {
                                st.offset = Some(last.offset + 1);
                            }
                            return Some((
                                Ok(crate::pb::ConsumeResponse {
                                    topic: st.req.topic.clone(),
                                    partition: st.req.partition,
                                    high_watermark: outcome.high_watermark,
                                    error_code: 0,
                                    records,
                                    ..Default::default()
                                }),
                                st,
                            ));
                        }
                        Err(e) => {
                            st.done = true;
                            return Some((Err(e), st));
                        }
                    }
                }
            },
        );
        Ok(Box::pin(stream))
    }

    async fn subscribe(
        &self,
        req: crate::pb::GroupSubscribeRequest,
        _ctx: CallCtx,
    ) -> Result<ResponseStream<crate::pb::GroupSubscribeResponse>, Status> {
        if req.group_id.is_empty() {
            return Err(Status::invalid_argument("group_id is required"));
        }
        if req.topics.is_empty() {
            return Err(Status::invalid_argument("at least one topic is required"));
        }
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let broker = self.broker.clone();
        let groups = self.groups.clone();
        tokio::spawn(async move {
            run_subscribe(broker, groups, req, tx).await;
        });
        let stream = futures_util::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|item| (item, rx))
        });
        Ok(Box::pin(stream))
    }

    async fn list_offsets(
        &self,
        req: crate::pb::ListOffsetsRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::ListOffsetsResponse, Status> {
        let (offset, timestamp_ms, error_code) =
            self.broker
                .list_offsets(&req.topic, req.partition, req.timestamp, req.read_committed)
                .await?;
        Ok(crate::pb::ListOffsetsResponse {
            offset,
            timestamp_ms,
            error_code,
            ..Default::default()
        })
    }

    async fn commit_offset(
        &self,
        req: crate::pb::CommitOffsetRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::CommitOffsetResponse, Status> {
        if !req.session_id.is_empty() {
            // Transactional commit: stage the offset on the
            // producer session. EndTransaction attaches it with
            // AddOffsetsToTxn + TxnOffsetCommit so it becomes
            // visible exactly when the transaction commits.
            let session = self
                .sessions
                .lock()
                .await
                .get(&req.session_id)
                .cloned()
                .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown producer session"))?;
            if session.transactional_id.is_empty() {
                return Ok(crate::pb::CommitOffsetResponse {
                    error_code: -1,
                    ..Default::default()
                });
            }
            session.txn_groups.lock().await.insert(req.group_id.clone());
            session.txn_offsets.lock().await.insert(
                (req.group_id.clone(), req.topic.clone(), req.partition),
                (req.committed_offset, req.metadata.clone()),
            );
            return Ok(crate::pb::CommitOffsetResponse { error_code: 0, ..Default::default() });
        }
        let session = self.groups.lock().await.get(&req.group_id).cloned();
        let (generation_id, member_id, group_instance_id) = match session {
            Some(session) => (
                session.generation_id,
                session.member_id,
                session.group_instance_id,
            ),
            None => (-1, String::new(), None),
        };
        let error_code = self
            .broker
            .offset_commit(
                &req.group_id,
                generation_id,
                &member_id,
                group_instance_id.as_deref(),
                &req.topic,
                req.partition,
                req.committed_offset,
                &req.metadata,
            )
            .await?;
        Ok(crate::pb::CommitOffsetResponse { error_code, ..Default::default() })
    }

    async fn fetch_offset(
        &self,
        req: crate::pb::FetchOffsetRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::FetchOffsetResponse, Status> {
        let (committed_offset, metadata, error_code) =
            self.broker.offset_fetch(&req.group_id, &req.topic, req.partition).await?;
        Ok(crate::pb::FetchOffsetResponse {
            committed_offset,
            metadata,
            error_code,
            ..Default::default()
        })
    }

    async fn create_topics(
        &self,
        req: crate::pb::CreateTopicsRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::CreateTopicsResponse, Status> {
        let topics = req
            .topics
            .iter()
            .map(|topic| (topic.name.clone(), topic.num_partitions, topic.replication_factor))
            .collect();
        let timeout_ms = if req.timeout_ms > 0 { req.timeout_ms } else { 30_000 };
        let results = self.broker.create_topics(topics, timeout_ms, req.validate_only).await?;
        Ok(crate::pb::CreateTopicsResponse {
            results: results
                .into_iter()
                .map(|(name, error_code)| crate::pb::TopicError {
                    name,
                    error_code,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        })
    }

    async fn delete_topics(
        &self,
        req: crate::pb::DeleteTopicsRequest,
        _ctx: CallCtx,
    ) -> Result<crate::pb::DeleteTopicsResponse, Status> {
        let timeout_ms = if req.timeout_ms > 0 { req.timeout_ms } else { 30_000 };
        let results = self.broker.delete_topics(req.topics.clone(), timeout_ms).await?;
        Ok(crate::pb::DeleteTopicsResponse {
            results: results
                .into_iter()
                .map(|(name, error_code)| crate::pb::TopicError {
                    name,
                    error_code,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        })
    }
}

fn group_error(error_code: i32, message: impl Into<String>) -> crate::pb::GroupSubscribeResponse {
    crate::pb::GroupSubscribeResponse {
        group_error: Some(Box::new(crate::pb::GroupError {
            error_code,
            message: message.into(),
            ..Default::default()
        })),
        ..Default::default()
    }
}

async fn compute_assignments(
    broker: &Broker,
    protocol: &str,
    members: &[(String, Option<String>, Vec<u8>)],
) -> Result<Vec<(String, Vec<u8>)>, Status> {
    let mut member_topics: Vec<(String, Vec<String>)> = members
        .iter()
        .map(|(member_id, _, subscription)| (member_id.clone(), decode_subscription(subscription)))
        .collect();
    member_topics.sort_by(|a, b| a.0.cmp(&b.0));

    let mut all_topics = std::collections::BTreeSet::new();
    for (_, topics) in &member_topics {
        for topic in topics {
            all_topics.insert(topic.clone());
        }
    }

    let metadata = broker
        .metadata(all_topics.iter().cloned().collect(), false)
        .await?;
    let mut partitions_by_topic: std::collections::BTreeMap<String, Vec<i32>> =
        std::collections::BTreeMap::new();
    for topic in metadata.topics {
        if topic.error_code != 0 {
            continue;
        }
        let mut partitions: Vec<i32> = topic
            .partitions
            .iter()
            .filter(|partition| partition.error_code == 0)
            .map(|partition| partition.id)
            .collect();
        partitions.sort_unstable();
        partitions_by_topic.insert(topic.name, partitions);
    }

    let mut assigned: HashMap<String, Vec<(String, i32)>> = member_topics
        .iter()
        .map(|(member_id, _)| (member_id.clone(), Vec::new()))
        .collect();

    if protocol == "roundrobin" {
        let mut pairs: Vec<(String, i32)> = Vec::new();
        for (topic, partitions) in &partitions_by_topic {
            for partition in partitions {
                pairs.push((topic.clone(), *partition));
            }
        }
        pairs.sort();
        let mut cursor = 0usize;
        for (topic, partition) in pairs {
            for _ in 0..member_topics.len() {
                let (member_id, topics) = &member_topics[cursor % member_topics.len()];
                cursor += 1;
                if topics.contains(&topic) {
                    assigned
                        .get_mut(member_id)
                        .expect("assignment member")
                        .push((topic.clone(), partition));
                    break;
                }
            }
        }
    } else {
        // Kafka's range assignor: contiguous ranges, assigned
        // independently for each topic.
        for (topic, partitions) in &partitions_by_topic {
            let subscribers: Vec<&(String, Vec<String>)> = member_topics
                .iter()
                .filter(|(_, topics)| topics.contains(topic))
                .collect();
            if subscribers.is_empty() {
                continue;
            }
            let base = partitions.len() / subscribers.len();
            let extra = partitions.len() % subscribers.len();
            let mut cursor = 0usize;
            for (index, (member_id, _)) in subscribers.iter().enumerate() {
                let count = base + usize::from(index < extra);
                for partition in &partitions[cursor..cursor + count] {
                    assigned
                        .get_mut(member_id.as_str())
                        .expect("assignment member")
                        .push((topic.clone(), *partition));
                }
                cursor += count;
            }
        }
    }

    Ok(member_topics
        .iter()
        .map(|(member_id, _)| {
            let partitions = assigned.get(member_id).cloned().unwrap_or_default();
            (member_id.clone(), encode_assignment(&partitions))
        })
        .collect())
}

async fn run_subscribe(
    broker: Arc<Broker>,
    groups: Arc<Mutex<HashMap<String, GroupSession>>>,
    req: crate::pb::GroupSubscribeRequest,
    tx: tokio::sync::mpsc::UnboundedSender<Result<crate::pb::GroupSubscribeResponse, Status>>,
) {
    let session_timeout_ms = if req.session_timeout_ms > 0 {
        req.session_timeout_ms
    } else {
        45_000
    };
    let max_poll_records = if req.max_poll_records > 0 {
        req.max_poll_records as usize
    } else {
        500
    };
    let reset_timestamp = if req.auto_offset_reset.eq_ignore_ascii_case("earliest") {
        -2
    } else {
        -1
    };
    let group_instance_id = if req.group_instance_id.is_empty() {
        None
    } else {
        Some(req.group_instance_id.clone())
    };
    let mut member_id = String::new();

    'membership: loop {
        if tx.is_closed() {
            return;
        }

        let coordinator = match broker.coordinator_fresh(&req.group_id, 0).await {
            Ok(conn) => conn,
            Err(error) => {
                let _ = tx.send(Ok(group_error(-1, error.message.clone())));
                return;
            }
        };
        let subscription = encode_subscription(&req.topics);
        let protocols = vec![
            ("range".to_string(), subscription.clone()),
            ("roundrobin".to_string(), subscription),
        ];
        let join = match broker
            .join_group(
                &coordinator,
                &req.group_id,
                &member_id,
                group_instance_id.as_deref(),
                session_timeout_ms,
                300_000,
                protocols,
            )
            .await
        {
            Ok(join) => join,
            Err(error) => {
                let _ = tx.send(Ok(group_error(-1, error.message.clone())));
                return;
            }
        };

        // MEMBER_ID_REQUIRED carries the broker-assigned ID;
        // retry immediately with it, matching Kafka clients.
        if join.error_code == 79 && !join.member_id.is_empty() {
            member_id = join.member_id;
            continue 'membership;
        }
        // Transient coordinator states on a fresh broker:
        // COORDINATOR_LOAD_IN_PROGRESS (14),
        // COORDINATOR_NOT_AVAILABLE (15), NOT_COORDINATOR (16).
        // Rediscover and retry instead of failing the subscription.
        if matches!(join.error_code, 14 | 15 | 16) {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            continue 'membership;
        }
        if join.error_code != 0 {
            let _ = tx.send(Ok(group_error(
                join.error_code,
                format!("kafka JoinGroup failed with error {}", join.error_code),
            )));
            return;
        }
        member_id = join.member_id.clone();

        let assignments = if join.leader_id == member_id {
            match compute_assignments(&broker, &join.protocol_name, &join.members).await {
                Ok(assignments) => assignments,
                Err(error) => {
                    let _ = tx.send(Ok(group_error(-1, error.message.clone())));
                    let _ = broker
                        .leave_group(
                            &coordinator,
                            &req.group_id,
                            &member_id,
                            group_instance_id.as_deref(),
                        )
                        .await;
                    return;
                }
            }
        } else {
            Vec::new()
        };

        let (sync_error, assignment_bytes) = match broker
            .sync_group(
                &coordinator,
                &req.group_id,
                join.generation_id,
                &member_id,
                group_instance_id.as_deref(),
                &join.protocol_name,
                assignments,
            )
            .await
        {
            Ok(result) => result,
            Err(error) => {
                let _ = tx.send(Ok(group_error(-1, error.message.clone())));
                let _ = broker
                    .leave_group(
                        &coordinator,
                        &req.group_id,
                        &member_id,
                        group_instance_id.as_deref(),
                    )
                    .await;
                return;
            }
        };
        if matches!(sync_error, 22 | 25 | 27) {
            if sync_error == 25 {
                member_id.clear();
            }
            continue 'membership;
        }
        if sync_error != 0 {
            let _ = tx.send(Ok(group_error(
                sync_error,
                format!("kafka SyncGroup failed with error {sync_error}"),
            )));
            let _ = broker
                .leave_group(
                    &coordinator,
                    &req.group_id,
                    &member_id,
                    group_instance_id.as_deref(),
                )
                .await;
            return;
        }

        let assigned = decode_assignment(&assignment_bytes);
        groups.lock().await.insert(
            req.group_id.clone(),
            GroupSession {
                generation_id: join.generation_id,
                member_id: member_id.clone(),
                group_instance_id: group_instance_id.clone(),
            },
        );
        if tx
            .send(Ok(crate::pb::GroupSubscribeResponse {
                assignment: Some(Box::new(crate::pb::Assignment {
                    generation_id: join.generation_id,
                    member_id: member_id.clone(),
                    partitions: assigned
                        .iter()
                        .map(|(topic, partition)| crate::pb::TopicPartition {
                            topic: topic.clone(),
                            partition: *partition,
                            ..Default::default()
                        })
                        .collect(),
                    ..Default::default()
                })),
                ..Default::default()
            }))
            .is_err()
        {
            groups.lock().await.remove(&req.group_id);
            let _ = broker
                .leave_group(
                    &coordinator,
                    &req.group_id,
                    &member_id,
                    group_instance_id.as_deref(),
                )
                .await;
            return;
        }

        let mut positions: HashMap<(String, i32), i64> = HashMap::new();
        for (topic, partition) in &assigned {
            let committed = broker.offset_fetch(&req.group_id, topic, *partition).await;
            let position = match committed {
                Ok((offset, _, error_code)) if error_code == 0 && offset >= 0 => offset,
                _ => match broker
                    .list_offsets(topic, *partition, reset_timestamp, req.read_committed)
                    .await
                {
                    Ok((offset, _, error_code)) if error_code == 0 => offset,
                    _ => 0,
                },
            };
            positions.insert((topic.clone(), *partition), position);
        }

        let heartbeat_interval = std::time::Duration::from_millis(
            ((session_timeout_ms / 3).max(1_000)) as u64,
        );
        let mut last_heartbeat = tokio::time::Instant::now() - heartbeat_interval;
        let mut rejoin = false;

        'poll: loop {
            if tx.is_closed() {
                break 'poll;
            }
            if last_heartbeat.elapsed() >= heartbeat_interval {
                match broker
                    .heartbeat(
                        &coordinator,
                        &req.group_id,
                        join.generation_id,
                        &member_id,
                        group_instance_id.as_deref(),
                    )
                    .await
                {
                    Ok(0) => {
                    }
                    Ok(22 | 27) => {
                        rejoin = true;
                        break 'poll;
                    }
                    Ok(25) => {
                        member_id.clear();
                        rejoin = true;
                        break 'poll;
                    }
                    Ok(error_code) => {
                        let _ = tx.send(Ok(group_error(
                            error_code,
                            format!("kafka Heartbeat failed with error {error_code}"),
                        )));
                        break 'poll;
                    }
                    Err(error) => {
                        let _ = tx.send(Ok(group_error(-1, error.message.clone())));
                        break 'poll;
                    }
                }
                last_heartbeat = tokio::time::Instant::now();
            }

            let mut fetched_any = false;
            for (topic, partition) in &assigned {
                let key = (topic.clone(), *partition);
                let position = *positions.get(&key).unwrap_or(&0);
                let outcome = match broker
                    .fetch(
                        topic,
                        *partition,
                        position,
                        300,
                        1,
                        4 * 1024 * 1024,
                        req.read_committed,
                    )
                    .await
                {
                    Ok(outcome) => outcome,
                    Err(error) => {
                        let _ = tx.send(Ok(group_error(-1, error.message.clone())));
                        break 'poll;
                    }
                };
                if outcome.error_code == 1 || outcome.error_code == 9 {
                    // OFFSET_OUT_OF_RANGE (1): apply the reset
                    // policy. (9, REPLICA_NOT_AVAILABLE, is kept
                    // on the same reset path for brokers that
                    // surface a range problem that way.)
                    if let Ok((offset, _, error_code)) = broker
                        .list_offsets(topic, *partition, reset_timestamp, req.read_committed)
                        .await
                    {
                        if error_code == 0 {
                            positions.insert(key, offset);
                        }
                    }
                    continue;
                }
                if outcome.error_code != 0 {
                    let _ = tx.send(Ok(group_error(
                        outcome.error_code,
                        format!(
                            "kafka Fetch failed with error {}",
                            outcome.error_code
                        ),
                    )));
                    break 'poll;
                }
                if outcome.records.is_empty() {
                    continue;
                }
                fetched_any = true;
                let mut records = outcome.records;
                if records.len() > max_poll_records {
                    records.truncate(max_poll_records);
                }
                if let Some(last) = records.last() {
                    positions.insert(key, last.offset + 1);
                }
                if tx
                    .send(Ok(crate::pb::GroupSubscribeResponse {
                        batch: Some(Box::new(crate::pb::RecordBatch {
                            topic: topic.clone(),
                            partition: *partition,
                            high_watermark: outcome.high_watermark,
                            records,
                            ..Default::default()
                        })),
                        ..Default::default()
                    }))
                    .is_err()
                {
                    break 'poll;
                }
            }
            if !fetched_any {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }

        if !rejoin {
            // Final exit: drop the commit-offset session and
            // leave the group. On a rejoin (rebalance /
            // heartbeat 22/25/27) the member must NOT leave:
            // leaving first makes the broker forget the
            // member id, and the rejoin then fails with
            // UNKNOWN_MEMBER_ID (25).
            let mut active_groups = groups.lock().await;
            if active_groups
                .get(&req.group_id)
                .is_some_and(|session| session.member_id == member_id)
            {
                active_groups.remove(&req.group_id);
            }
            drop(active_groups);
            let _ = broker
                .leave_group(
                    &coordinator,
                    &req.group_id,
                    &member_id,
                    group_instance_id.as_deref(),
                )
                .await;
            return;
        }
    }
}
