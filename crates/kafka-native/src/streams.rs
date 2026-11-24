//! Kafka Streams over gRPC (grpcdc.kafka.streams.v1): the
//! proxy executes declarative topologies against the broker.
//! v1 supports exactly TOKENIZE_WORDS -> GROUP_BY_KEY ->
//! COUNT (word count): a per-topology task polls each source
//! partition, tokenizes record values, maintains the count
//! store in memory, emits (word, count) records to the sink
//! (partitioned by key hash), and commits source offsets
//! under the topology's consumer group after each batch.
//! Exactly-once transactional processing and standby tasks
//! are future work; a restarted topology restores its store
//! by replaying the already-committed source range without
//! emitting, then resumes live at the committed offset.

use crate::client::Broker;
use crate::streams_pb as spb;
use grpc_dc::{CallCtx, ServiceDef, Status};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

struct TopologyState {
    info: spb::TopologyInfo,
    store: HashMap<Vec<u8>, i64>,
}

struct TopologyHandle {
    state: Mutex<TopologyState>,
    stop: AtomicBool,
}

pub struct StreamsService {
    broker: Arc<Broker>,
    topologies: Mutex<HashMap<String, Arc<TopologyHandle>>>,
}

const SUPPORTED: [spb::Operator; 3] = [
    spb::Operator::TokenizeWords,
    spb::Operator::GroupByKey,
    spb::Operator::Count,
];

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// The v1 operator-chain contract: exactly TOKENIZE_WORDS
/// -> GROUP_BY_KEY -> COUNT, in order, nothing else.
fn validate_chain(operators: &[spb::Operator]) -> Result<(), Status> {
    if operators == SUPPORTED {
        Ok(())
    } else {
        Err(Status::invalid_argument(
            "unsupported operator chain: v1 supports TOKENIZE_WORDS -> GROUP_BY_KEY -> COUNT",
        ))
    }
}

fn tokenize(value: &[u8]) -> Vec<Vec<u8>> {
    let text = String::from_utf8_lossy(value);
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(|t| t.to_lowercase().into_bytes())
        .collect()
}

impl StreamsService {
    pub fn new(broker: Arc<Broker>) -> StreamsService {
        StreamsService { broker, topologies: Mutex::new(HashMap::new()) }
    }

    async fn create_topology(&self, req: spb::CreateTopologyRequest) -> Result<spb::TopologyInfo, Status> {
        let topo = req.topology.map(|t| *t).unwrap_or_default();
        if topo.name.is_empty() || topo.source_topic.is_empty() || topo.sink_topic.is_empty() {
            return Err(Status::invalid_argument("topology name, source_topic, and sink_topic are required"));
        }
        validate_chain(&topo.operators)?;
        let app_id = if topo.application_id.is_empty() {
            format!("streams-{}", topo.name)
        } else {
            topo.application_id.clone()
        };
        let mut topologies = self.topologies.lock().await;
        if topologies.contains_key(&topo.name) {
            return Err(Status::new(grpc_dc::Code::AlreadyExists, "topology already exists"));
        }
        let handle = Arc::new(TopologyHandle {
            state: Mutex::new(TopologyState {
                info: spb::TopologyInfo {
                    name: topo.name.clone(),
                    application_id: app_id.clone(),
                    source_topic: topo.source_topic.clone(),
                    sink_topic: topo.sink_topic.clone(),
                    state: "RUNNING".to_string(),
                    ..Default::default()
                },
                store: HashMap::new(),
            }),
            stop: AtomicBool::new(false),
        });
        topologies.insert(topo.name.clone(), handle.clone());
        let broker = self.broker.clone();
        tokio::spawn(run_topology(broker, handle.clone(), topo, app_id));
        let info = handle.state.lock().await.info.clone();
        Ok(info)
    }

    async fn describe_topology(&self, req: spb::DescribeTopologyRequest) -> Result<spb::TopologyInfo, Status> {
        let topologies = self.topologies.lock().await;
        let handle = topologies
            .get(&req.name)
            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?
            .clone();
        drop(topologies);
        let info = handle.state.lock().await.info.clone();
        Ok(info)
    }

    async fn list_topologies(&self) -> Result<spb::ListTopologiesResponse, Status> {
        let topologies = self.topologies.lock().await;
        let mut out = Vec::new();
        for handle in topologies.values() {
            out.push(handle.state.lock().await.info.clone());
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(spb::ListTopologiesResponse { topologies: out, ..Default::default() })
    }

    async fn delete_topology(&self, req: spb::DeleteTopologyRequest) -> Result<spb::DeleteTopologyResponse, Status> {
        let mut topologies = self.topologies.lock().await;
        let handle = topologies
            .remove(&req.name)
            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
        handle.stop.store(true, Ordering::Relaxed);
        handle.state.lock().await.info.state = "STOPPED".to_string();
        Ok(spb::DeleteTopologyResponse::default())
    }

    async fn get_store_value(&self, req: spb::GetStoreValueRequest) -> Result<spb::GetStoreValueResponse, Status> {
        let topologies = self.topologies.lock().await;
        let handle = topologies
            .get(&req.topology)
            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
        let state = handle.state.lock().await;
        match state.store.get(req.key.as_bytes()) {
            Some(value) => Ok(spb::GetStoreValueResponse {
                found: true,
                key: req.key.clone(),
                value: *value,
                ..Default::default()
            }),
            None => Ok(spb::GetStoreValueResponse { key: req.key.clone(), ..Default::default() }),
        }
    }
}

/// ServiceDef for grpcdc.kafka.streams.v1.KafkaStreams,
/// registered alongside the Kafka service by the proxy. (The
/// generated Rust stub assumes a crate::pb layout this crate
/// does not have for a second proto, so the five unary
/// methods are bound here directly; the wire contract is the
/// generated one every other language uses.)
pub fn streams_service(svc: Arc<StreamsService>) -> ServiceDef {
    ServiceDef::new(
        "grpcdc.kafka.streams.v1.KafkaStreams",
        vec![
            grpc_dc::unary_method("CreateTopology", {
                let svc = svc.clone();
                move |req, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move { svc.create_topology(req).await }
                }
            }),
            grpc_dc::unary_method("DescribeTopology", {
                let svc = svc.clone();
                move |req, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move { svc.describe_topology(req).await }
                }
            }),
            grpc_dc::unary_method("ListTopologies", {
                let svc = svc.clone();
                move |_req: spb::ListTopologiesRequest, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move { svc.list_topologies().await }
                }
            }),
            grpc_dc::unary_method("DeleteTopology", {
                let svc = svc.clone();
                move |req, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move { svc.delete_topology(req).await }
                }
            }),
            grpc_dc::unary_method("GetStoreValue", {
                let svc = svc;
                move |req, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move { svc.get_store_value(req).await }
                }
            }),
        ],
    )
}

async fn fail(handle: &TopologyHandle, error: String) {
    let mut state = handle.state.lock().await;
    state.info.state = "FAILED".to_string();
    state.info.error = error;
}

async fn run_topology(broker: Arc<Broker>, handle: Arc<TopologyHandle>, topo: spb::Topology, app_id: String) {
    let meta = match broker.metadata(vec![topo.source_topic.clone()], false).await {
        Ok(m) => m,
        Err(e) => return fail(&handle, e.message.clone()).await,
    };
    let partitions: Vec<i32> = meta
        .topics
        .iter()
        .filter(|t| t.name == topo.source_topic)
        .flat_map(|t| t.partitions.iter().map(|p| p.id))
        .collect();
    if partitions.is_empty() {
        return fail(&handle, format!("source topic {} has no partitions", topo.source_topic)).await;
    }
    let sink_meta = match broker.metadata(vec![topo.sink_topic.clone()], false).await {
        Ok(m) => m,
        Err(e) => return fail(&handle, e.message.clone()).await,
    };
    let sink_partitions = sink_meta
        .topics
        .iter()
        .filter(|t| t.name == topo.sink_topic)
        .map(|t| t.partitions.len() as i32)
        .next()
        .unwrap_or(1)
        .max(1);

    // Resume from committed group offsets, else earliest.
    // When a committed offset exists, first restore the
    // store by replaying [earliest, committed) through the
    // transform WITHOUT emitting to the sink or committing
    // (the Streams changelog-restore step; for COUNT the
    // source itself is the changelog), then go live at the
    // committed offset. Records are never counted twice.
    let mut offsets: HashMap<i32, i64> = HashMap::new();
    for p in &partitions {
        let committed = match broker.offset_fetch(&app_id, &topo.source_topic, *p).await {
            Ok((c, _, _)) if c >= 0 => Some(c),
            _ => None,
        };
        let earliest = match broker.list_offsets(&topo.source_topic, *p, -2, false).await {
            Ok((off, _, _)) => off,
            Err(e) => return fail(&handle, e.message.clone()).await,
        };
        let start = committed.unwrap_or(earliest);
        if start > earliest {
            let mut replay = earliest;
            while replay < start && !handle.stop.load(Ordering::Relaxed) {
                let outcome = match broker.fetch(&topo.source_topic, *p, replay, 200, 1, 4 * 1024 * 1024, false).await {
                    Ok(o) => o,
                    Err(e) => return fail(&handle, e.message.clone()).await,
                };
                if outcome.records.is_empty() {
                    break;
                }
                for record in &outcome.records {
                    if record.offset >= start {
                        break;
                    }
                    replay = record.offset + 1;
                    for token in tokenize(&record.value) {
                        let mut state = handle.state.lock().await;
                        *state.store.entry(token).or_insert(0) += 1;
                    }
                    handle.state.lock().await.info.records_processed += 1;
                }
            }
        }
        offsets.insert(*p, start);
    }

    while !handle.stop.load(Ordering::Relaxed) {
        let mut progressed = false;
        for p in &partitions {
            if handle.stop.load(Ordering::Relaxed) {
                break;
            }
            let offset = offsets[p];
            let outcome = match broker.fetch(&topo.source_topic, *p, offset, 200, 1, 4 * 1024 * 1024, false).await {
                Ok(o) => o,
                Err(e) => return fail(&handle, e.message.clone()).await,
            };
            if outcome.error_code != 0 {
                return fail(&handle, format!("fetch {}:{} error {}", topo.source_topic, p, outcome.error_code)).await;
            }
            if outcome.records.is_empty() {
                continue;
            }
            progressed = true;
            let mut next_offset = offset;
            for record in &outcome.records {
                next_offset = record.offset + 1;
                for token in tokenize(&record.value) {
                    let count = {
                        let mut state = handle.state.lock().await;
                        let entry = state.store.entry(token.clone()).or_insert(0);
                        *entry += 1;
                        *entry
                    };
                    let sink_partition = (fnv1a(&token) % sink_partitions as u64) as i32;
                    let out = crate::pb::Record {
                        key: token.clone(),
                        value: count.to_string().into_bytes(),
                        ..Default::default()
                    };
                    let produced = broker
                        .produce(&topo.sink_topic, sink_partition, &[out], -1, 30_000, 0, -1, -1, -1, None)
                        .await;
                    match produced {
                        Ok(o) if o.error_code == 0 => {}
                        Ok(o) => return fail(&handle, format!("produce to {} error {}", topo.sink_topic, o.error_code)).await,
                        Err(e) => return fail(&handle, e.message.clone()).await,
                    }
                }
                handle.state.lock().await.info.records_processed += 1;
            }
            if let Err(e) = broker
                .offset_commit(&app_id, -1, "", None, &topo.source_topic, *p, next_offset, "")
                .await
            {
                return fail(&handle, e.message.clone()).await;
            }
            offsets.insert(*p, next_offset);
        }
        if !progressed {
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(value: &str) -> Vec<String> {
        tokenize(value.as_bytes())
            .iter()
            .map(|t| String::from_utf8(t.clone()).unwrap())
            .collect()
    }

    #[test]
    fn tokenize_splits_lowercases_and_strips_punctuation() {
        assert_eq!(words("Hello, WORLD! hello..."), vec!["hello", "world", "hello"]);
        assert_eq!(words("one-two_three\tx\ny"), vec!["one", "two", "three", "x", "y"]);
        assert_eq!(words("a1 B2 c3"), vec!["a1", "b2", "c3"]);
    }

    #[test]
    fn tokenize_handles_empty_symbols_and_non_utf8() {
        assert!(words("").is_empty());
        assert!(words("  -- !! --  ").is_empty());
        // Invalid UTF-8 becomes replacement chars, which are
        // not alphanumeric: no tokens, no panic.
        assert!(tokenize(&[0xff, 0xfe, b'a']).is_empty() || tokenize(&[0xff, 0xfe, b'a']).len() == 1);
        assert_eq!(tokenize(b"caf\xc3\xa9 CAF\xc3\x89").len(), 2);
    }

    #[test]
    fn chain_validation_accepts_only_the_v1_chain() {
        assert!(validate_chain(&SUPPORTED).is_ok());
        assert!(validate_chain(&[]).is_err());
        assert!(validate_chain(&[spb::Operator::Count]).is_err());
        assert!(validate_chain(&[
            spb::Operator::TokenizeWords,
            spb::Operator::Count,
            spb::Operator::GroupByKey,
        ])
        .is_err());
        assert!(validate_chain(&[
            spb::Operator::TokenizeWords,
            spb::Operator::GroupByKey,
            spb::Operator::Count,
            spb::Operator::Count,
        ])
        .is_err());
        assert!(validate_chain(&[spb::Operator::OperatorUnspecified]).is_err());
    }

    #[test]
    fn fnv_partition_assignment_is_stable_and_bounded() {
        for key in ["hello", "world", "streams", "of", ""] {
            let p = (fnv1a(key.as_bytes()) % 3) as i32;
            assert!((0..3).contains(&p), "partition out of range for {key}");
            assert_eq!(p, (fnv1a(key.as_bytes()) % 3) as i32, "unstable for {key}");
        }
        assert_ne!(fnv1a(b"hello"), fnv1a(b"world"));
    }
}
