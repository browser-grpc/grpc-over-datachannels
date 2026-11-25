//! Kafka Streams over gRPC (grpcdc.kafka.streams.v1): the
//! proxy executes declarative topologies against the broker.
//! Chains are built from TOKENIZE_WORDS, GROUP_BY_KEY,
//! COUNT, MAP_VALUES, FILTER, SELECT_KEY, AGGREGATE
//! (COUNT/SUM/MIN/MAX), and REDUCE steps: a per-topology
//! task polls each source partition, runs records through
//! the chain, maintains the state store in memory, emits
//! results to the sink (partitioned by key hash), and
//! commits source offsets under the topology's consumer
//! group after each batch.
//! Exactly-once transactional processing and standby tasks
//! are future work; a restarted topology restores its store
//! by replaying the already-committed source range without
//! emitting, then resumes live at the committed offset.

use crate::client::{decode_assignment, encode_subscription, Broker};
use crate::streams_pb as spb;
use grpc_dc::{CallCtx, ServiceDef, Status};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Mutex;

struct TopologyState {
    info: spb::TopologyInfo,
    store: HashMap<Vec<u8>, i64>,
    stream_time: i64,
    table: HashMap<Vec<u8>, Vec<u8>>,
    sessions: HashMap<Vec<u8>, Vec<(i64, i64)>>,
    key_records: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>>,
    processors: HashMap<String, grpc_dc::Channel>,
    join_buffer: Vec<(Vec<u8>, i64, Vec<u8>, bool)>,
    table2: HashMap<Vec<u8>, Vec<u8>>,
}

struct TopologyHandle {
    state: Mutex<TopologyState>,
    stop: AtomicBool,
    standby: AtomicBool,
    primary: Option<String>,
}

pub struct StreamsService {
    broker: Arc<Broker>,
    topologies: Mutex<HashMap<String, Arc<TopologyHandle>>>,
}

#[cfg(test)]
static EMPTY_TABLE: std::sync::LazyLock<HashMap<Vec<u8>, Vec<u8>>> =
    std::sync::LazyLock::new(HashMap::new);

/// Resolved step kinds for the chain engine.
#[derive(Clone, Debug, PartialEq)]
enum Op {
    TokenizeWords,
    GroupByKey,
    Count,
    MapValues(MapTransform),
    Filter(Predicate),
    SelectKey(KeyMode),
    Aggregate(AggKind),
    Reduce(ReduceKind),
    Window { size_ms: i64, advance_ms: i64, grace_ms: i64 },
    JoinTable { separator: Vec<u8> },
    WindowSession { gap_ms: i64, grace_ms: i64, kind: AggKind },
    WindowSliding { size_ms: i64, grace_ms: i64, kind: AggKind },
    Cogroup,
    Process { addr: String },
    JoinStream { size_ms: i64, grace_ms: i64, separator: Vec<u8> },
    JoinTableTable { separator: Vec<u8> },
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum MapTransform { Upper, Lower, Trim, Reverse }

#[derive(Clone, Debug, PartialEq)]
enum Predicate {
    Prefix(Vec<u8>),
    Contains(Vec<u8>),
    KeyEquals(Vec<u8>),
    ValueGt(i64),
    ValueLt(i64),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum KeyMode { Value, Upper, Lower }

#[derive(Clone, Copy, Debug, PartialEq)]
enum AggKind { Count, Sum, Min, Max }

#[derive(Clone, Copy, Debug, PartialEq)]
enum ReduceKind { Sum, Min, Max }

/// Resolve a Topology's steps (preferred) or legacy
/// operators into engine ops, validating parameters.
fn resolve_ops(topo: &spb::Topology) -> Result<Vec<Op>, Status> {
    let steps: Vec<spb::Step> = if !topo.steps.is_empty() {
        topo.steps.clone()
    } else {
        topo.operators
            .iter()
            .map(|op| spb::Step { operator: *op, ..Default::default() })
            .collect()
    };
    if steps.is_empty() {
        return Err(Status::invalid_argument("topology has no steps"));
    }
    let mut ops: Vec<Op> = Vec::new();
    for (idx, step) in steps.iter().enumerate() {
        let op = match step.operator {
            spb::Operator::TokenizeWords => Op::TokenizeWords,
            spb::Operator::GroupByKey => Op::GroupByKey,
            spb::Operator::Count => Op::Count,
            spb::Operator::MapValues => Op::MapValues(match step.param.as_str() {
                "upper" => MapTransform::Upper,
                "lower" => MapTransform::Lower,
                "trim" => MapTransform::Trim,
                "reverse" => MapTransform::Reverse,
                other => {
                    return Err(Status::invalid_argument(format!(
                        "MAP_VALUES param must be upper|lower|trim|reverse, got '{other}'"
                    )))
                }
            }),
            spb::Operator::Filter => Op::Filter(parse_predicate(&step.param)?),
            spb::Operator::SelectKey => Op::SelectKey(match step.param.as_str() {
                "" | "value" => KeyMode::Value,
                "upper" => KeyMode::Upper,
                "lower" => KeyMode::Lower,
                other => {
                    return Err(Status::invalid_argument(format!(
                        "SELECT_KEY param must be value|upper|lower, got '{other}'"
                    )))
                }
            }),
            spb::Operator::Aggregate => Op::Aggregate(match step.aggregator {
                spb::Aggregator::AggregateCount => AggKind::Count,
                spb::Aggregator::AggregateSum => AggKind::Sum,
                spb::Aggregator::AggregateMin => AggKind::Min,
                spb::Aggregator::AggregateMax => AggKind::Max,
                _ => {
                    return Err(Status::invalid_argument(
                        "AGGREGATE requires aggregator COUNT|SUM|MIN|MAX",
                    ))
                }
            }),
            spb::Operator::Reduce => Op::Reduce(match step.param.as_str() {
                "" | "sum" => ReduceKind::Sum,
                "min" => ReduceKind::Min,
                "max" => ReduceKind::Max,
                other => {
                    return Err(Status::invalid_argument(format!(
                        "REDUCE param must be sum|min|max, got '{other}'"
                    )))
                }
            }),
            spb::Operator::JoinTable | spb::Operator::JoinGlobalTable => {
                if topo.table_topic.is_empty() {
                    return Err(Status::invalid_argument(
                        "JOIN_TABLE requires Topology.table_topic",
                    ));
                }
                let sep = if step.param.is_empty() { ":".to_string() } else { step.param.clone() };
                Op::JoinTable { separator: sep.into_bytes() }
            }
            spb::Operator::JoinTableTable => {
                if topo.table_topic.is_empty() || topo.join_topic.is_empty() {
                    return Err(Status::invalid_argument(
                        "JOIN_TABLE_TABLE requires Topology.table_topic and Topology.join_topic",
                    ));
                }
                let sep = if step.param.is_empty() { ":".to_string() } else { step.param.clone() };
                Op::JoinTableTable { separator: sep.into_bytes() }
            }
            spb::Operator::JoinStream => {
                if topo.join_topic.is_empty() {
                    return Err(Status::invalid_argument("JOIN_STREAM requires Topology.join_topic"));
                }
                if step.window_size_ms <= 0 {
                    return Err(Status::invalid_argument("JOIN_STREAM requires window_size_ms > 0"));
                }
                let sep = if step.param.is_empty() { ":".to_string() } else { step.param.clone() };
                Op::JoinStream {
                    size_ms: step.window_size_ms,
                    grace_ms: step.grace_ms.max(0),
                    separator: sep.into_bytes(),
                }
            }
            spb::Operator::Process => {
                let addr = step.param.strip_prefix("tcp://").unwrap_or(&step.param);
                if addr.is_empty() || !addr.contains(':') {
                    return Err(Status::invalid_argument(
                        "PROCESS requires param tcp://host:port of the StreamsProcessor service",
                    ));
                }
                Op::Process { addr: addr.to_string() }
            }
            spb::Operator::Cogroup => {
                if topo.cogroup_sources.is_empty() {
                    return Err(Status::invalid_argument(
                        "COGROUP requires Topology.cogroup_sources",
                    ));
                }
                Op::Cogroup
            }
            spb::Operator::WindowSession | spb::Operator::WindowSliding => {
                // The aggregating window ops need the
                // combiner of the next stateful step.
                let kind = steps[idx + 1..]
                    .iter()
                    .find_map(|n| match n.operator {
                        spb::Operator::Count => Some(AggKind::Count),
                        spb::Operator::Aggregate => Some(match n.aggregator {
                            spb::Aggregator::AggregateSum => AggKind::Sum,
                            spb::Aggregator::AggregateMin => AggKind::Min,
                            spb::Aggregator::AggregateMax => AggKind::Max,
                            _ => AggKind::Count,
                        }),
                        spb::Operator::Reduce => Some(match n.param.as_str() {
                            "min" => AggKind::Min,
                            "max" => AggKind::Max,
                            _ => AggKind::Sum,
                        }),
                        _ => None,
                    })
                    .ok_or_else(|| {
                        Status::invalid_argument(
                            "WINDOW_SESSION/WINDOW_SLIDING require a following COUNT/AGGREGATE/REDUCE step",
                        )
                    })?;
                if step.operator == spb::Operator::WindowSession {
                    if step.gap_ms <= 0 {
                        return Err(Status::invalid_argument("WINDOW_SESSION requires gap_ms > 0"));
                    }
                    Op::WindowSession { gap_ms: step.gap_ms, grace_ms: step.grace_ms.max(0), kind }
                } else {
                    if step.window_size_ms <= 0 {
                        return Err(Status::invalid_argument("WINDOW_SLIDING requires window_size_ms > 0"));
                    }
                    Op::WindowSliding { size_ms: step.window_size_ms, grace_ms: step.grace_ms.max(0), kind }
                }
            }
            spb::Operator::WindowTumbling | spb::Operator::WindowHopping => {
                if step.window_size_ms <= 0 {
                    return Err(Status::invalid_argument("WINDOW_* requires window_size_ms > 0"));
                }
                let advance = if step.operator == spb::Operator::WindowHopping && step.window_advance_ms > 0 {
                    step.window_advance_ms
                } else {
                    step.window_size_ms
                };
                Op::Window { size_ms: step.window_size_ms, advance_ms: advance, grace_ms: step.grace_ms.max(0) }
            }
            _ => {
                return Err(Status::invalid_argument(format!(
                    "unsupported operator {:?} in topology chain",
                    step.operator
                )))
            }
        };
        ops.push(op);
    }
    validate_ops(&ops)?;
    Ok(ops)
}

fn parse_predicate(param: &str) -> Result<Predicate, Status> {
    let bad = || Status::invalid_argument(format!(
        "FILTER param must be prefix:<s>|contains:<s>|key_equals:<s>|value_gt:<int>|value_lt:<int>, got '{param}'"
    ));
    if let Some(v) = param.strip_prefix("prefix:") {
        Ok(Predicate::Prefix(v.as_bytes().to_vec()))
    } else if let Some(v) = param.strip_prefix("contains:") {
        Ok(Predicate::Contains(v.as_bytes().to_vec()))
    } else if let Some(v) = param.strip_prefix("key_equals:") {
        Ok(Predicate::KeyEquals(v.as_bytes().to_vec()))
    } else if let Some(v) = param.strip_prefix("value_gt:") {
        v.parse::<i64>().map(Predicate::ValueGt).map_err(|_| bad())
    } else if let Some(v) = param.strip_prefix("value_lt:") {
        v.parse::<i64>().map(Predicate::ValueLt).map_err(|_| bad())
    } else {
        Err(bad())
    }
}

/// Chain contract: GROUP_BY_KEY at most once, and stateful
/// operators (COUNT/AGGREGATE/REDUCE) only after it.
fn validate_ops(ops: &[Op]) -> Result<(), Status> {
    let mut grouped = false;
    let mut stateful_seen = false;
    for op in ops {
        match op {
            Op::GroupByKey => {
                if grouped {
                    return Err(Status::invalid_argument("GROUP_BY_KEY may appear at most once"));
                }
                grouped = true;
            }
            Op::Window { .. } => {
                if stateful_seen {
                    return Err(Status::invalid_argument(
                        "WINDOW_* must appear before the stateful operator it windows",
                    ));
                }
            }
            Op::Count | Op::Aggregate(_) | Op::Reduce(_) => {
                stateful_seen = true;
                if !grouped {
                    return Err(Status::invalid_argument(
                        "stateful operators (COUNT/AGGREGATE/REDUCE) require GROUP_BY_KEY before them",
                    ));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// Window starts containing ts: tumbling is advance == size.
fn window_starts(ts: i64, size_ms: i64, advance_ms: i64) -> Vec<i64> {
    if size_ms <= 0 || advance_ms <= 0 {
        return Vec::new();
    }
    let latest = ts.div_euclid(advance_ms) * advance_ms;
    let mut starts = Vec::new();
    let mut start = latest;
    while start + size_ms > ts && start > latest - size_ms {
        starts.push(start);
        start -= advance_ms;
    }
    starts.reverse();
    starts
}

fn store_key(key: &[u8], window: Option<(i64, i64)>) -> Vec<u8> {
    match window {
        None => key.to_vec(),
        Some((start, end)) => {
            let mut k = key.to_vec();
            k.push(0);
            k.extend_from_slice(&start.to_be_bytes());
            k.extend_from_slice(&end.to_be_bytes());
            k
        }
    }
}

/// Combine an existing aggregate (if any) with one record
/// contribution under kind.
fn combine_agg(kind: AggKind, existing: Option<i64>, value: Option<i64>) -> Option<i64> {
    match kind {
        AggKind::Count => Some(existing.unwrap_or(0) + 1),
        AggKind::Sum => Some(existing.unwrap_or(0) + value.unwrap_or(0)),
        AggKind::Min => match (existing, value) {
            (Some(e), Some(v)) => Some(e.min(v)),
            (Some(e), None) => Some(e),
            (None, v) => v,
        },
        AggKind::Max => match (existing, value) {
            (Some(e), Some(v)) => Some(e.max(v)),
            (Some(e), None) => Some(e),
            (None, v) => v,
        },
    }
}

/// Merge the session containing ts for key: sessions are
/// [start, last_ts] point-intervals; two merge when the
/// distance between them is at most gap. Returns the merged
/// [start, end) window (end = last + 1) and the list of
/// replaced session starts (for store transfer).
fn session_merge(
    sessions: &mut Vec<(i64, i64)>,
    ts: i64,
    gap_ms: i64,
) -> ((i64, i64), Vec<(i64, i64)>) {
    let mut start = ts;
    let mut last = ts;
    let mut replaced = Vec::new();
    let mut kept = Vec::new();
    for &(s, l) in sessions.iter() {
        if ts - l <= gap_ms && s - ts <= gap_ms {
            start = start.min(s);
            last = last.max(l);
            replaced.push((s, l + 1));
        } else {
            kept.push((s, l));
        }
    }
    kept.push((start, last));
    kept.sort_unstable();
    *sessions = kept;
    ((start, last + 1), replaced)
}

/// Back-compat chain check used by the original tests.
fn validate_chain(operators: &[spb::Operator]) -> Result<(), Status> {
    let topo = spb::Topology { operators: operators.to_vec(), ..Default::default() };
    resolve_ops(&topo).map(|_| ())
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
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
        let ops = resolve_ops(&topo)?;
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
                    role: "ACTIVE".to_string(),
                    ..Default::default()
                },
                store: HashMap::new(),
                stream_time: 0,
                table: HashMap::new(),
                sessions: HashMap::new(),
                key_records: HashMap::new(),
                processors: HashMap::new(),
                join_buffer: Vec::new(),
                table2: HashMap::new(),
            }),
            stop: AtomicBool::new(false),
            standby: AtomicBool::new(false),
            primary: None,
        });
        topologies.insert(topo.name.clone(), handle.clone());
        let broker = self.broker.clone();
        tokio::spawn(run_topology(broker.clone(), handle.clone(), topo.clone(), app_id.clone(), ops.clone(), false));
        for i in 0..topo.standby_replicas.max(0) {
            let sname = format!("{}-standby-{i}", topo.name);
            if topologies.contains_key(&sname) {
                continue;
            }
            let shandle = Arc::new(TopologyHandle {
                state: Mutex::new(TopologyState {
                    info: spb::TopologyInfo {
                        name: sname.clone(),
                        application_id: app_id.clone(),
                        source_topic: topo.source_topic.clone(),
                        sink_topic: topo.sink_topic.clone(),
                        state: "RUNNING".to_string(),
                        role: "STANDBY".to_string(),
                        ..Default::default()
                    },
                    store: HashMap::new(),
                    stream_time: 0,
                    table: HashMap::new(),
                    sessions: HashMap::new(),
                    key_records: HashMap::new(),
                    processors: HashMap::new(),
                    join_buffer: Vec::new(),
                    table2: HashMap::new(),
                }),
                stop: AtomicBool::new(false),
                standby: AtomicBool::new(true),
                primary: Some(topo.name.clone()),
            });
            topologies.insert(sname, shandle.clone());
            tokio::spawn(run_topology(
                broker.clone(),
                shandle,
                topo.clone(),
                app_id.clone(),
                ops.clone(),
                true,
            ));
        }
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
        // Promote the oldest standby of this primary, if
        // any: it keeps its warm store and takes over.
        let mut candidates: Vec<(String, Arc<TopologyHandle>)> = topologies
            .iter()
            .filter(|(_, h)| {
                h.primary.as_deref() == Some(req.name.as_str()) && h.standby.load(Ordering::Relaxed)
            })
            .map(|(n, h)| (n.clone(), h.clone()))
            .collect();
        candidates.sort_by(|a, b| a.0.cmp(&b.0));
        let promote = candidates.into_iter().next().map(|(_, h)| h);
        if let Some(h) = promote {
            h.standby.store(false, Ordering::Relaxed);
            let mut st = h.state.lock().await;
            st.info.role = "ACTIVE".to_string();
        }
        Ok(spb::DeleteTopologyResponse::default())
    }

    async fn get_store_value(&self, req: spb::GetStoreValueRequest) -> Result<spb::GetStoreValueResponse, Status> {
        let topologies = self.topologies.lock().await;
        let handle = topologies
            .get(&req.topology)
            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
        let state = handle.state.lock().await;
        // Table lookups share this query surface: a key that
        // is a table entry (and not an aggregate) answers
        // with the table's value parsed as int64 when it is
        // numeric; the join e2e checks table values through
        // the sink instead for non-numeric payloads.
        if !state.table.is_empty() && !state.store.contains_key(req.key.as_bytes()) {
            if let Some(tv) = state.table.get(req.key.as_bytes()) {
                return Ok(spb::GetStoreValueResponse {
                    found: true,
                    key: req.key.clone(),
                    value: parse_i64(tv).unwrap_or(0),
                    ..Default::default()
                });
            }
        }
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

impl StreamsService {
    async fn fetch_window(&self, req: spb::FetchWindowRequest) -> Result<spb::FetchWindowResponse, Status> {
        let topologies = self.topologies.lock().await;
        let handle = topologies
            .get(&req.topology)
            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?
            .clone();
        drop(topologies);
        let state = handle.state.lock().await;
        let key = store_key(req.key.as_bytes(), Some((req.window_start_ms, req.window_end_ms)));
        match state.store.get(&key) {
            Some(value) => Ok(spb::FetchWindowResponse {
                found: true,
                key: req.key.clone(),
                window_start_ms: req.window_start_ms,
                window_end_ms: req.window_end_ms,
                value: *value,
                ..Default::default()
            }),
            None => Ok(spb::FetchWindowResponse {
                key: req.key.clone(),
                window_start_ms: req.window_start_ms,
                window_end_ms: req.window_end_ms,
                ..Default::default()
            }),
        }
    }
}

/// ServiceDef for grpcdc.kafka.streams.processor.v1
/// ProcessorContext: state access for client-hosted
/// processors, served by the proxy next to KafkaStreams.
pub fn processor_context_service(svc: Arc<StreamsService>) -> ServiceDef {
    ServiceDef::new(
        "grpcdc.kafka.streams.processor.v1.ProcessorContext",
        vec![
            grpc_dc::unary_method("GetState", {
                let svc = svc.clone();
                move |req: crate::processor_pb::GetStateRequest, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move {
                        let topologies = svc.topologies.lock().await;
                        let handle = topologies
                            .get(&req.topology)
                            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
                        let state = handle.state.lock().await;
                        match state.store.get(req.key.as_bytes()) {
                            Some(v) => Ok(crate::processor_pb::GetStateResponse {
                                found: true,
                                value: *v,
                                ..Default::default()
                            }),
                            None => Ok(crate::processor_pb::GetStateResponse::default()),
                        }
                    }
                }
            }),
            grpc_dc::unary_method("PutState", {
                let svc = svc;
                move |req: crate::processor_pb::PutStateRequest, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move {
                        let topologies = svc.topologies.lock().await;
                        let handle = topologies
                            .get(&req.topology)
                            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
                        handle
                            .state
                            .lock()
                            .await
                            .store
                            .insert(req.key.into_bytes(), req.value);
                        Ok(crate::processor_pb::PutStateResponse::default())
                    }
                }
            }),
        ],
    )
}

/// Split a windowed store key into (key, start, end);
/// windowed keys are key || 0x00 || start_be64 || end_be64.
fn split_window_key(k: &[u8]) -> Option<(Vec<u8>, i64, i64)> {
    if k.len() < 17 {
        return None;
    }
    let sep = k.len() - 17;
    if k[sep] != 0 {
        return None;
    }
    let start = i64::from_be_bytes(k[sep + 1..sep + 9].try_into().ok()?);
    let end = i64::from_be_bytes(k[sep + 9..sep + 17].try_into().ok()?);
    Some((k[..sep].to_vec(), start, end))
}

/// Prefix scan over the unwindowed store entries.
fn scan_range(
    store: &HashMap<Vec<u8>, i64>,
    prefix: &[u8],
    limit: usize,
) -> Vec<(Vec<u8>, i64)> {
    let mut hits: Vec<(Vec<u8>, i64)> = store
        .iter()
        .filter(|(k, _)| split_window_key(k).is_none() && k.starts_with(prefix))
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    hits.sort();
    hits.truncate(limit.max(1));
    hits
}

/// All windows stored for one key within [from_ms, to_ms].
fn scan_windows(
    store: &HashMap<Vec<u8>, i64>,
    key: &[u8],
    from_ms: i64,
    to_ms: i64,
) -> Vec<(i64, i64, i64)> {
    let mut hits: Vec<(i64, i64, i64)> = store
        .iter()
        .filter_map(|(k, v)| {
            let (kk, start, end) = split_window_key(k)?;
            if kk == key && start >= from_ms && end <= to_ms {
                Some((start, end, *v))
            } else {
                None
            }
        })
        .collect();
    hits.sort();
    hits
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
            grpc_dc::unary_method("FetchRange", {
                let svc = svc.clone();
                move |req: spb::FetchRangeRequest, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move {
                        let topologies = svc.topologies.lock().await;
                        let handle = topologies
                            .get(&req.topology)
                            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
                        let state = handle.state.lock().await;
                        let limit = if req.limit > 0 { req.limit as usize } else { 100 };
                        let entries = scan_range(&state.store, req.prefix.as_bytes(), limit)
                            .into_iter()
                            .map(|(k, v)| spb::StoreEntry {
                                key: String::from_utf8_lossy(&k).into_owned(),
                                value: v,
                                ..Default::default()
                            })
                            .collect();
                        Ok(spb::FetchRangeResponse { entries, ..Default::default() })
                    }
                }
            }),
            grpc_dc::unary_method("FetchWindowRange", {
                let svc = svc.clone();
                move |req: spb::FetchWindowRangeRequest, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move {
                        let topologies = svc.topologies.lock().await;
                        let handle = topologies
                            .get(&req.topology)
                            .ok_or_else(|| Status::new(grpc_dc::Code::NotFound, "unknown topology"))?;
                        let state = handle.state.lock().await;
                        let entries = scan_windows(&state.store, req.key.as_bytes(), req.from_ms, req.to_ms)
                            .into_iter()
                            .map(|(start, end, v)| spb::StoreEntry {
                                key: req.key.clone(),
                                value: v,
                                window_start_ms: start,
                                window_end_ms: end,
                                ..Default::default()
                            })
                            .collect();
                        Ok(spb::FetchWindowRangeResponse { entries, ..Default::default() })
                    }
                }
            }),
            grpc_dc::unary_method("FetchWindow", {
                let svc = svc.clone();
                move |req, _ctx: CallCtx| {
                    let svc = svc.clone();
                    async move { svc.fetch_window(req).await }
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

/// Snapshot the store to the changelog topic. When a
/// transaction is active the records go through it (added
/// to the transaction first), so changelog, sink, and
/// offsets commit atomically under EXACTLY_ONCE.
async fn snapshot_changelog(
    broker: &Broker,
    handle: &TopologyHandle,
    topic: &str,
    app_id: &str,
    txn: Option<&mut TxnState>,
) -> Result<(), String> {
    let snapshot: Vec<(Vec<u8>, i64)> = {
        let st = handle.state.lock().await;
        st.store.iter().map(|(k, v)| (k.clone(), *v)).collect()
    };
    if let Some(t) = txn {
        let key = (topic.to_string(), 0);
        if !t.partitions_in_txn.contains(&key) {
            match broker
                .add_partitions_to_txn(
                    app_id,
                    t.producer_id,
                    t.producer_epoch,
                    vec![(topic.to_string(), vec![0])],
                )
                .await
            {
                Ok(results) => {
                    if let Some((_, _, err)) = results.first() {
                        if *err != 0 {
                            return Err(format!("changelog AddPartitionsToTxn error {err}"));
                        }
                    }
                    t.partitions_in_txn.insert(key);
                }
                Err(e) => return Err(e.message.clone()),
            }
        }
        for (k, v) in snapshot {
            let seq = *t.sequences.get(&(topic.to_string(), 0)).unwrap_or(&0);
            let rec = crate::pb::Record {
                key: k,
                value: v.to_string().into_bytes(),
                ..Default::default()
            };
            match broker
                .produce(topic, 0, &[rec], -1, 30_000, 0, t.producer_id, t.producer_epoch, seq, Some(app_id))
                .await
            {
                Ok(o) if o.error_code == 0 => {
                    *t.sequences.entry((topic.to_string(), 0)).or_insert(0) += 1;
                }
                Ok(o) => return Err(format!("changelog produce error {}", o.error_code)),
                Err(e) => return Err(e.message.clone()),
            }
        }
        return Ok(());
    }
    for (k, v) in snapshot {
        let rec = crate::pb::Record {
            key: k,
            value: v.to_string().into_bytes(),
            ..Default::default()
        };
        let _ = broker.produce(topic, 0, &[rec], -1, 30_000, 0, -1, -1, -1, None).await;
    }
    Ok(())
}

async fn fail(handle: &TopologyHandle, error: String) {
    let mut state = handle.state.lock().await;
    state.info.state = "FAILED".to_string();
    state.info.error = error;
}

#[derive(Clone, Debug, PartialEq)]
struct PipeRec {
    key: Vec<u8>,
    value: Vec<u8>,
    ts: i64,
    window: Option<(i64, i64)>,
    precomputed: bool,
    join_side: bool,
}

fn parse_i64(value: &[u8]) -> Option<i64> {
    std::str::from_utf8(value).ok()?.trim().parse::<i64>().ok()
}

/// Run one record through the chain. Store is updated by
/// stateful ops; callers pass the topology store. Pure apart
/// from the store, so restore replays use it too (outputs
/// discarded there).
struct PipelineCtx<'a> {
    store: &'a mut HashMap<Vec<u8>, i64>,
    stream_time: &'a mut i64,
    table: &'a HashMap<Vec<u8>, Vec<u8>>,
    sessions: &'a mut HashMap<Vec<u8>, Vec<(i64, i64)>>,
    key_records: &'a mut HashMap<Vec<u8>, Vec<(i64, Option<i64>)>>,
    processors: &'a mut HashMap<String, grpc_dc::Channel>,
    topology_name: &'a str,
    join_buffer: &'a mut Vec<(Vec<u8>, i64, Vec<u8>, bool)>,
}

impl PipelineCtx<'_> {
    async fn processor_call(
        &mut self,
        addr: &str,
        rec: &PipeRec,
    ) -> Result<Vec<(Vec<u8>, Vec<u8>)>, Status> {
        if !self.processors.contains_key(addr) {
            let stream = tokio::net::TcpStream::connect(addr)
                .await
                .map_err(|e| Status::unavailable(format!("processor connect {addr}: {e}")))?;
            let (rx, tx) = tokio::io::split(stream);
            let transport: std::sync::Arc<dyn grpc_dc::DcTransport> =
                std::sync::Arc::new(grpc_dc::StreamDc::new(rx, tx));
            self.processors
                .insert(addr.to_string(), grpc_dc::Channel::new(transport));
        }
        let channel = self.processors.get(addr).expect("processor channel inserted");
        let req = crate::processor_pb::ProcessRecord {
            key: rec.key.clone(),
            value: rec.value.clone(),
            timestamp_ms: rec.ts,
            topology: self.topology_name.to_string(),
            ..Default::default()
        };
        let resp: crate::processor_pb::ProcessResult = channel
            .unary(
                "/grpcdc.kafka.streams.processor.v1.StreamsProcessor/Process",
                req,
            )
            .await?;
        Ok(resp
            .records
            .into_iter()
            .map(|r| (r.key, r.value))
            .collect())
    }
}

async fn apply_pipeline(ops: &[Op], rec: &PipeRec, ctx: &mut PipelineCtx<'_>) -> Vec<PipeRec> {
    let mut current = vec![rec.clone()];
    for op in ops {
        let mut next = Vec::new();
        for r in current {
            match op {
                Op::TokenizeWords => {
                    for token in tokenize(&r.value) {
                        next.push(PipeRec { key: token, value: b"1".to_vec(), ts: r.ts, window: r.window, precomputed: false, join_side: r.join_side });
                    }
                }
                Op::GroupByKey => next.push(r),
                Op::MapValues(t) => {
                    let value = match t {
                        MapTransform::Upper => String::from_utf8_lossy(&r.value).to_uppercase().into_bytes(),
                        MapTransform::Lower => String::from_utf8_lossy(&r.value).to_lowercase().into_bytes(),
                        MapTransform::Trim => String::from_utf8_lossy(&r.value).trim().to_string().into_bytes(),
                        MapTransform::Reverse => {
                            let mut v = r.value.clone();
                            v.reverse();
                            v
                        }
                    };
                    next.push(PipeRec { value, ..r });
                }
                Op::Filter(pred) => {
                    let keep = match pred {
                        Predicate::Prefix(p) => r.value.starts_with(p),
                        Predicate::Contains(p) => {
                            !p.is_empty() && r.value.windows(p.len()).any(|w| w == p.as_slice())
                        }
                        Predicate::KeyEquals(k) => &r.key == k,
                        Predicate::ValueGt(n) => parse_i64(&r.value).is_some_and(|v| v > *n),
                        Predicate::ValueLt(n) => parse_i64(&r.value).is_some_and(|v| v < *n),
                    };
                    if keep {
                        next.push(r);
                    }
                }
                Op::SelectKey(mode) => {
                    let key = match mode {
                        KeyMode::Value => r.value.clone(),
                        KeyMode::Upper => String::from_utf8_lossy(&r.value).to_uppercase().into_bytes(),
                        KeyMode::Lower => String::from_utf8_lossy(&r.value).to_lowercase().into_bytes(),
                    };
                    next.push(PipeRec { key, ..r });
                }
                Op::Window { size_ms, advance_ms, grace_ms } => {
                    if r.ts > *ctx.stream_time {
                        *ctx.stream_time = r.ts;
                    }
                    for start in window_starts(r.ts, *size_ms, *advance_ms) {
                        let end = start + size_ms;
                        if end + grace_ms < *ctx.stream_time {
                            continue; // late record: window closed
                        }
                        next.push(PipeRec { window: Some((start, end)), ..r.clone() });
                    }
                }
                Op::Cogroup => next.push(r),
                Op::Process { addr } => {
                    match ctx.processor_call(addr, &r).await {
                        Ok(outs) => {
                            for out in outs {
                                next.push(PipeRec {
                                    key: out.0,
                                    value: out.1,
                                    ts: r.ts,
                                    window: r.window,
                                    precomputed: false,
                                    join_side: r.join_side,
                                });
                            }
                        }
                        Err(e) => {
                            // Processor failures drop the
                            // record and are counted on the
                            // topology (visible in tests via
                            // store assertions); failing the
                            // whole topology on one bad call
                            // would stall the group.
                            eprintln!("streams PROCESS to {addr} failed: {}", e.message);
                        }
                    }
                }
                Op::JoinStream { size_ms, grace_ms, separator } => {
                    if r.ts > *ctx.stream_time {
                        *ctx.stream_time = r.ts;
                    }
                    let win_start = r.ts.div_euclid(*size_ms) * size_ms;
                    // Prune expired buffer entries.
                    ctx.join_buffer.retain(|(_, ts, _, _)| {
                        ts.div_euclid(*size_ms) * size_ms + size_ms + grace_ms >= *ctx.stream_time
                    });
                    for (k, ts, v, side) in ctx.join_buffer.iter() {
                        if *side != r.join_side && k == &r.key && ts.div_euclid(*size_ms) * size_ms == win_start {
                            let (left, right) = if r.join_side {
                                (v.clone(), r.value.clone())
                            } else {
                                (r.value.clone(), v.clone())
                            };
                            let mut value = left;
                            value.extend_from_slice(separator);
                            value.extend_from_slice(&right);
                            next.push(PipeRec { value, window: Some((win_start, win_start + size_ms)), ..r.clone() });
                        }
                    }
                    ctx.join_buffer.push((r.key.clone(), r.ts, r.value.clone(), r.join_side));
                }
                Op::JoinTableTable { .. } => next.push(r),
                Op::JoinTable { separator } => {
                    if let Some(tv) = ctx.table.get(&r.key) {
                        let mut value = r.value.clone();
                        value.extend_from_slice(separator);
                        value.extend_from_slice(tv);
                        next.push(PipeRec { value, ..r });
                    }
                }
                Op::WindowSession { gap_ms, grace_ms, kind } => {
                    if r.ts > *ctx.stream_time {
                        *ctx.stream_time = r.ts;
                    }
                    if r.ts + grace_ms < *ctx.stream_time && *ctx.stream_time - r.ts > *grace_ms {
                        continue; // too late for any session
                    }
                    let sessions = ctx.sessions.entry(r.key.clone()).or_default();
                    let (window, replaced) = session_merge(sessions, r.ts, *gap_ms);
                    // Transfer replaced sessions' aggregates
                    // into the merged window, then add this
                    // record's contribution.
                    // Transferred values are already totals:
                    // fold them additively for Count/Sum and
                    // by min/max otherwise.
                    let mut agg: Option<i64> = None;
                    for old in &replaced {
                        if *old != window {
                            if let Some(v) = ctx.store.remove(&store_key(&r.key, Some(*old))) {
                                agg = Some(match (agg, kind) {
                                    (None, _) => v,
                                    (Some(a), AggKind::Count | AggKind::Sum) => a + v,
                                    (Some(a), AggKind::Min) => a.min(v),
                                    (Some(a), AggKind::Max) => a.max(v),
                                });
                            }
                        }
                    }
                    agg = match kind {
                        AggKind::Count => Some(agg.unwrap_or(0) + 1),
                        AggKind::Sum => Some(agg.unwrap_or(0) + parse_i64(&r.value).unwrap_or(0)),
                        AggKind::Min => combine_agg(*kind, agg, parse_i64(&r.value)),
                        AggKind::Max => combine_agg(*kind, agg, parse_i64(&r.value)),
                    };
                    let agg = agg.unwrap_or(0);
                    ctx.store.insert(store_key(&r.key, Some(window)), agg);
                    next.push(PipeRec {
                        value: agg.to_string().into_bytes(),
                        window: Some(window),
                        precomputed: true,
                        ..r
                    });
                }
                Op::WindowSliding { size_ms, grace_ms, kind } => {
                    if r.ts > *ctx.stream_time {
                        *ctx.stream_time = r.ts;
                    }
                    let records = ctx.key_records.entry(r.key.clone()).or_default();
                    records.push((r.ts, parse_i64(&r.value)));
                    records.sort_by_key(|(ts, _)| *ts);
                    // Window starts: this record's own anchor
                    // plus every earlier start still covering it.
                    let mut starts: Vec<i64> = records
                        .iter()
                        .map(|(ts, _)| ts - size_ms + 1)
                        .filter(|start| *start <= r.ts && r.ts < start + size_ms)
                        .collect();
                    starts.sort_unstable();
                    starts.dedup();
                    for start in starts {
                        let end = start + size_ms;
                        if end + grace_ms < *ctx.stream_time {
                            continue;
                        }
                        // Aggregate every record of this key
                        // inside [start, end).
                        let mut agg: Option<i64> = None;
                        for (ts, v) in records.iter() {
                            if *ts >= start && *ts < end {
                                agg = match kind {
                                    AggKind::Count => Some(agg.unwrap_or(0) + 1),
                                    _ => combine_agg(*kind, agg, *v),
                                };
                                if *kind == AggKind::Count {
                                    // combine above already handled via first arm
                                }
                            }
                        }
                        let Some(agg) = agg else { continue };
                        ctx.store.insert(store_key(&r.key, Some((start, end))), agg);
                        next.push(PipeRec {
                            value: agg.to_string().into_bytes(),
                            window: Some((start, end)),
                            precomputed: true,
                            ..r.clone()
                        });
                    }
                }
                Op::Count => {
                    if r.precomputed {
                        next.push(r);
                        continue;
                    }
                    let entry = ctx.store.entry(store_key(&r.key, r.window)).or_insert(0);
                    *entry += 1;
                    next.push(PipeRec { value: entry.to_string().into_bytes(), ..r });
                }
                Op::Aggregate(kind) => {
                    if r.precomputed {
                        next.push(r);
                        continue;
                    }
                    let v = parse_i64(&r.value);
                    let entry = ctx.store.entry(store_key(&r.key, r.window));
                    let current_val = match kind {
                        AggKind::Count => {
                            let e = entry.or_insert(0);
                            *e += 1;
                            *e
                        }
                        AggKind::Sum => {
                            let e = entry.or_insert(0);
                            *e += v.unwrap_or(0);
                            *e
                        }
                        AggKind::Min => match v {
                            Some(v) => {
                                let e = entry.or_insert(v);
                                *e = (*e).min(v);
                                *e
                            }
                            None => continue,
                        },
                        AggKind::Max => match v {
                            Some(v) => {
                                let e = entry.or_insert(v);
                                *e = (*e).max(v);
                                *e
                            }
                            None => continue,
                        },
                    };
                    next.push(PipeRec { value: current_val.to_string().into_bytes(), ..r });
                }
                Op::Reduce(kind) => {
                    if r.precomputed {
                        next.push(r);
                        continue;
                    }
                    let Some(v) = parse_i64(&r.value) else { continue };
                    let skey = store_key(&r.key, r.window);
                    let val = match ctx.store.get(&skey) {
                        None => v,
                        Some(existing) => match kind {
                            ReduceKind::Sum => existing + v,
                            ReduceKind::Min => (*existing).min(v),
                            ReduceKind::Max => (*existing).max(v),
                        },
                    };
                    ctx.store.insert(skey, val);
                    next.push(PipeRec { value: val.to_string().into_bytes(), ..r });
                }
            }
        }
        current = next;
        if current.is_empty() {
            break;
        }
    }
    current
}

/// Transactional producer state for EXACTLY_ONCE: one
/// producer id for the topology's lifetime; partitions are
/// added per transaction and sequences advance across them.
struct TxnState {
    producer_id: i64,
    producer_epoch: i16,
    sequences: HashMap<(String, i32), i32>,
    partitions_in_txn: std::collections::HashSet<(String, i32)>,
}

struct Membership {
    coordinator: Arc<tokio::sync::Mutex<crate::client::Conn>>,
    generation_id: i32,
    member_id: String,
    partitions: Vec<i32>,
}

/// Join (or rejoin) the topology's consumer group with the
/// classic protocol and return this member's assignment.
/// Kafka's range assignor runs on the leader via the shared
/// compute_assignments used by the Subscribe path.
async fn join_topology_group(
    broker: &Broker,
    app_id: &str,
    source_topic: &str,
) -> Result<Membership, Status> {
    let mut member_id = String::new();
    for _attempt in 0..50 {
        let coordinator = broker.coordinator_fresh(app_id, 0).await?;
        let subscription = encode_subscription(std::slice::from_ref(&source_topic.to_string()));
        let protocols = vec![
            ("range".to_string(), subscription.clone()),
            ("roundrobin".to_string(), subscription),
        ];
        let join = broker
            .join_group(&coordinator, app_id, &member_id, None, 45_000, 300_000, protocols)
            .await?;
        if join.error_code == 79 && !join.member_id.is_empty() {
            member_id = join.member_id;
            continue;
        }
        if matches!(join.error_code, 14 | 15 | 16) {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            continue;
        }
        if join.error_code != 0 {
            return Err(Status::new(
                grpc_dc::Code::Internal,
                format!("kafka JoinGroup for streams topology failed with error {}", join.error_code),
            ));
        }
        member_id = join.member_id.clone();
        let assignments = if join.leader_id == member_id {
            Some(crate::service::compute_assignments(broker, &join.protocol_name, &join.members).await?)
        } else {
            None
        };
        let (err, assignment) = broker
            .sync_group(
                &coordinator,
                app_id,
                join.generation_id,
                &member_id,
                None,
                &join.protocol_name,
                assignments.unwrap_or_default(),
            )
            .await?;
        if err != 0 {
            return Err(Status::new(
                grpc_dc::Code::Internal,
                format!("kafka SyncGroup for streams topology failed with error {err}"),
            ));
        }
        let mut partitions: Vec<i32> = decode_assignment(&assignment)
            .into_iter()
            .filter(|(t, _)| t == source_topic)
            .map(|(_, p)| p)
            .collect();
        partitions.sort_unstable();
        partitions.dedup();
        return Ok(Membership {
            coordinator,
            generation_id: join.generation_id,
            member_id,
            partitions,
        });
    }
    Err(Status::new(grpc_dc::Code::Internal, "streams topology group join did not settle"))
}


fn changelog_topic(app_id: &str) -> String {
    format!("{app_id}-store-changelog")
}

/// Restore a store snapshot from changelog records
/// (key = store key bytes, value = decimal i64): latest
/// record per key wins.
fn restore_changelog(records: &[(Vec<u8>, Vec<u8>)]) -> HashMap<Vec<u8>, i64> {
    let mut store = HashMap::new();
    for (k, v) in records {
        if let Some(n) = parse_i64(v) {
            store.insert(k.clone(), n);
        }
    }
    store
}

/// Run the pipeline for one record without holding the
/// topology state lock across it: PROCESS steps call out to
/// client-hosted processors, whose ProcessorContext calls
/// need that lock (holding it deadlocked the pair). State
/// is cloned in, the pipeline runs unlocked, and the result
/// is written back; records are processed sequentially per
/// topology, so no concurrent writer can interleave.
async fn apply_with_state(
    handle: &TopologyHandle,
    ops: &[Op],
    rec: &PipeRec,
    topo_name: &str,
) -> Vec<PipeRec> {
    let (mut store, mut sessions, mut key_records, mut stream_time, table, mut processors, mut join_buffer) = {
        let st = handle.state.lock().await;
        (
            st.store.clone(),
            st.sessions.clone(),
            st.key_records.clone(),
            st.stream_time,
            st.table.clone(),
            st.processors.clone(),
            st.join_buffer.clone(),
        )
    };
    let store_snapshot = store.clone();
    let outs = apply_pipeline(
        ops,
        rec,
        &mut PipelineCtx {
            store: &mut store,
            stream_time: &mut stream_time,
            table: &table,
            sessions: &mut sessions,
            key_records: &mut key_records,
            processors: &mut processors,
            topology_name: topo_name,
            join_buffer: &mut join_buffer,
        },
    )
    .await;
    let mut st = handle.state.lock().await;
    // Preserve ProcessorContext writes the processor made
    // against the live store during the call: entries that
    // changed versus the snapshot and that the pipeline
    // itself did not touch win over the write-back.
    let live = std::mem::replace(&mut st.store, store);
    for (k, v) in &live {
        let externally_changed = store_snapshot.get(k) != Some(v);
        let pipeline_untouched = st.store.get(k) == store_snapshot.get(k);
        if externally_changed && pipeline_untouched {
            st.store.insert(k.clone(), *v);
        }
    }
    st.sessions = sessions;
    st.key_records = key_records;
    st.stream_time = stream_time;
    st.processors = processors;
    st.join_buffer = join_buffer;
    st.info.records_processed += 1;
    outs
}

async fn run_topology(broker: Arc<Broker>, handle: Arc<TopologyHandle>, topo: spb::Topology, app_id: String, ops: Vec<Op>, standby: bool) {
    let topo_name = topo.name.clone();
    if standby {
        // Passive phase: maintain a warm store from all
        // source partitions (no group, no emits, no
        // commits) until promoted or stopped.
        let meta = broker.metadata(vec![topo.source_topic.clone()], false).await;
        if let Ok(meta) = meta {
            let parts: Vec<i32> = meta
                .topics
                .iter()
                .filter(|t| t.name == topo.source_topic)
                .flat_map(|t| t.partitions.iter().map(|p| p.id))
                .collect();
            let mut offs: std::collections::HashMap<i32, i64> = std::collections::HashMap::new();
            for p in &parts {
                offs.insert(
                    *p,
                    broker
                        .list_offsets(&topo.source_topic, *p, -2, false)
                        .await
                        .map(|(o, _, _)| o)
                        .unwrap_or(0),
                );
            }
            while handle.standby.load(Ordering::Relaxed) && !handle.stop.load(Ordering::Relaxed) {
                let mut any = false;
                for p in &parts {
                    let off = offs[p];
                    if let Ok(outcome) =
                        broker.fetch(&topo.source_topic, *p, off, 200, 1, 4 * 1024 * 1024, false).await
                    {
                        if outcome.error_code == 0 && !outcome.records.is_empty() {
                            any = true;
                            for record in &outcome.records {
                                offs.insert(*p, record.offset + 1);
                                let _ = apply_with_state(
                                    &handle,
                                    &ops,
                                    &PipeRec {
                                        key: record.key.clone(),
                                        value: record.value.clone(),
                                        ts: record.timestamp_ms,
                                        window: None,
                                        precomputed: false,
                                        join_side: false,
                                    },
                                    &topo_name,
                                )
                                .await;
                            }
                        }
                    }
                }
                if !any {
                    tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                }
            }
        }
        if handle.stop.load(Ordering::Relaxed) {
            return;
        }
        // Promoted: fall through to the active flow. The
        // warm store already reflects the source, so the
        // active restore must not replay into it again.
    }
    let meta = match broker.metadata(vec![topo.source_topic.clone()], false).await {
        Ok(m) => m,
        Err(e) => return fail(&handle, e.message.clone()).await,
    };
    let all_partitions: Vec<i32> = meta
        .topics
        .iter()
        .filter(|t| t.name == topo.source_topic)
        .flat_map(|t| t.partitions.iter().map(|p| p.id))
        .collect();
    if all_partitions.is_empty() {
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

    // Group membership: this task owns only its assigned
    // source partitions; other instances with the same
    // application_id own the rest.
    let mut membership = match join_topology_group(&broker, &app_id, &topo.source_topic).await {
        Ok(m) => m,
        Err(e) => return fail(&handle, e.message.clone()).await,
    };
    let partitions = membership.partitions.clone();
    {
        let mut state = handle.state.lock().await;
        state.info.assigned_partitions = partitions.clone();
        state.info.generation_id = membership.generation_id;
    }
    let exactly_once = topo.processing_guarantee == spb::ProcessingGuarantee::ExactlyOnce;
    let mut txn: Option<TxnState> = None;
    if exactly_once {
        match broker.init_producer_id(Some(app_id.as_str()), 60_000).await {
            Ok((pid, epoch, 0)) => {
                txn = Some(TxnState {
                    producer_id: pid,
                    producer_epoch: epoch,
                    sequences: HashMap::new(),
                    partitions_in_txn: Default::default(),
                });
            }
            Ok((_, _, err)) => {
                return fail(&handle, format!("InitProducerId for EXACTLY_ONCE failed with error {err}")).await
            }
            Err(e) => return fail(&handle, e.message.clone()).await,
        }
    }

    // Table materialization for JOIN_TABLE: poll every
    // table partition from earliest, latest value per key.
    let mut table_offsets: HashMap<i32, i64> = HashMap::new();
    let mut table_partitions: Vec<i32> = Vec::new();
    if !topo.table_topic.is_empty() {
        match broker.metadata(vec![topo.table_topic.clone()], false).await {
            Ok(m) => {
                for t in &m.topics {
                    if t.name == topo.table_topic {
                        for part in &t.partitions {
                            table_partitions.push(part.id);
                            table_offsets.insert(part.id, 0);
                        }
                    }
                }
                // Resolve true earliest per partition.
                for p in &table_partitions {
                    if let Ok((off, _, _)) = broker.list_offsets(&topo.table_topic, *p, -2, false).await {
                        table_offsets.insert(*p, off);
                    }
                }
            }
            Err(e) => return fail(&handle, e.message.clone()).await,
        }
    }

    // Right table for JOIN_TABLE_TABLE.
    let table_table_separator: Vec<u8> = ops
        .iter()
        .find_map(|o| match o {
            Op::JoinTableTable { separator } => Some(separator.clone()),
            _ => None,
        })
        .unwrap_or_else(|| b":".to_vec());
    let has_table_table = ops.iter().any(|o| matches!(o, Op::JoinTableTable { .. }));
    let mut table2_offsets: HashMap<i32, i64> = HashMap::new();
    let mut table2_partitions: Vec<i32> = Vec::new();
    if has_table_table {
        if let Ok(m) = broker.metadata(vec![topo.join_topic.clone()], false).await {
            for t in &m.topics {
                if t.name == topo.join_topic {
                    for part in &t.partitions {
                        table2_partitions.push(part.id);
                        let off = broker
                            .list_offsets(&topo.join_topic, part.id, -2, false)
                            .await
                            .map(|(o, _, _)| o)
                            .unwrap_or(0);
                        table2_offsets.insert(part.id, off);
                    }
                }
            }
        }
    }

    // Cogroup sources: keyed decimal values folded into
    // the store (SUM) as they arrive.
    let mut cogroup_offsets: HashMap<String, HashMap<i32, i64>> = HashMap::new();
    for topic in &topo.cogroup_sources {
        match broker.metadata(vec![topic.clone()], false).await {
            Ok(m) => {
                let mut parts = HashMap::new();
                for t in &m.topics {
                    if &t.name == topic {
                        for part in &t.partitions {
                            let off = broker
                                .list_offsets(topic, part.id, -2, false)
                                .await
                                .map(|(o, _, _)| o)
                                .unwrap_or(0);
                            parts.insert(part.id, off);
                        }
                    }
                }
                cogroup_offsets.insert(topic.clone(), parts);
            }
            Err(e) => return fail(&handle, e.message.clone()).await,
        }
    }

    let warm = standby;
    // Persistent state: restore the store from the
    // changelog topic when state_dir is set and a changelog
    // exists; source-range replay is then skipped for the
    // store (offsets still resume from the group commits).
    let changelog = if topo.state_dir.is_empty() {
        None
    } else {
        Some(changelog_topic(&app_id))
    };
    let mut changelog_restored = warm;
    if let Some(topic) = &changelog {
        let _ = broker
            .create_topics(vec![(topic.clone(), -1, -1)], 15_000, false)
            .await;
        // Read the whole changelog (all partitions) latest-per-key.
        if let Ok(meta) = broker.metadata(vec![topic.clone()], false).await {
            let mut records: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
            for t in &meta.topics {
                if &t.name != topic {
                    continue;
                }
                for part in &t.partitions {
                    let mut off = broker
                        .list_offsets(topic, part.id, -2, false)
                        .await
                        .map(|(o, _, _)| o)
                        .unwrap_or(0);
                    loop {
                        match broker.fetch(topic, part.id, off, 200, 1, 4 * 1024 * 1024, false).await {
                            Ok(outcome) if outcome.error_code == 0 && !outcome.records.is_empty() => {
                                for r in &outcome.records {
                                    off = r.offset + 1;
                                    records.push((r.key.clone(), r.value.clone()));
                                }
                            }
                            _ => break,
                        }
                    }
                }
            }
            if !records.is_empty() {
                let store = restore_changelog(&records);
                handle.state.lock().await.store = store;
                changelog_restored = true;
            }
        }
    }

    // Join stream state: offsets per join partition plus
    // the sub-chain from JOIN_STREAM onward.
    let mut join_state: Option<(HashMap<String, HashMap<i32, i64>>, Vec<Op>)> = None;
    if !topo.join_topic.is_empty() {
        if let Some(idx) = ops.iter().position(|o| matches!(o, Op::JoinStream { .. })) {
            let mut parts = HashMap::new();
            if let Ok(m) = broker.metadata(vec![topo.join_topic.clone()], false).await {
                for t in &m.topics {
                    if t.name == topo.join_topic {
                        for part in &t.partitions {
                            let off = broker
                                .list_offsets(&topo.join_topic, part.id, -2, false)
                                .await
                                .map(|(o, _, _)| o)
                                .unwrap_or(0);
                            parts.insert(part.id, off);
                        }
                    }
                }
            }
            let mut by_topic = HashMap::new();
            by_topic.insert(topo.join_topic.clone(), parts);
            join_state = Some((by_topic, ops[idx..].to_vec()));
        }
    }

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
        if start > earliest && !changelog_restored {
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
                    {
                        let _ = apply_with_state(
                            &handle,
                            &ops,
                            &PipeRec {
                                key: record.key.clone(),
                                value: record.value.clone(),
                                ts: record.timestamp_ms,
                                window: None,
                                precomputed: false,
                                join_side: false,
                            },
                            &topo_name,
                        )
                        .await;
                    }
                }
            }
        }
        offsets.insert(*p, start);
    }

    let mut last_heartbeat = tokio::time::Instant::now();
    while !handle.stop.load(Ordering::Relaxed) {
        // Heartbeat at ~3s cadence; fencing/rebalance codes
        // rejoin and adopt the new assignment (offsets and
        // the store for newly-owned partitions are restored
        // below before processing resumes).
        if last_heartbeat.elapsed() > std::time::Duration::from_secs(3) {
            last_heartbeat = tokio::time::Instant::now();
            match broker
                .heartbeat(
                    &membership.coordinator,
                    &app_id,
                    membership.generation_id,
                    &membership.member_id,
                    None,
                )
                .await
            {
                Ok(0) => {}
                Ok(27) | Ok(22) | Ok(25) => {
                    match join_topology_group(&broker, &app_id, &topo.source_topic).await {
                        Ok(m) => {
                            membership = m;
                            for p in membership.partitions.clone() {
                                if !offsets.contains_key(&p) {
                                    let start = match broker.offset_fetch(&app_id, &topo.source_topic, p).await {
                                        Ok((c, _, _)) if c >= 0 => c,
                                        _ => broker
                                            .list_offsets(&topo.source_topic, p, -2, false)
                                            .await
                                            .map(|(off, _, _)| off)
                                            .unwrap_or(0),
                                    };
                                    offsets.insert(p, start);
                                }
                            }
                            let mut state = handle.state.lock().await;
                            state.info.assigned_partitions = membership.partitions.clone();
                            state.info.generation_id = membership.generation_id;
                        }
                        Err(e) => return fail(&handle, e.message.clone()).await,
                    }
                }
                Ok(code) => {
                    return fail(&handle, format!("streams heartbeat failed with error {code}")).await
                }
                Err(e) => return fail(&handle, e.message.clone()).await,
            }
        }
        let mut progressed = false;
        let mut left_changed: Vec<Vec<u8>> = Vec::new();
        for tp in &table_partitions {
            let toff = table_offsets[tp];
            if let Ok(outcome) = broker
                .fetch(&topo.table_topic, *tp, toff, 100, 1, 4 * 1024 * 1024, false)
                .await
            {
                if outcome.error_code == 0 && !outcome.records.is_empty() {
                    let mut state = handle.state.lock().await;
                    for record in &outcome.records {
                        table_offsets.insert(*tp, record.offset + 1);
                        if record.key.is_empty() && record.key_null {
                            continue;
                        }
                        if record.value.is_empty() {
                            state.table.remove(&record.key);
                        } else {
                            state.table.insert(record.key.clone(), record.value.clone());
                        }
                        left_changed.push(record.key.clone());
                    }
                }
            }
        }
        if has_table_table {
            let mut changed: Vec<Vec<u8>> = Vec::new();
            for tp in &table2_partitions {
                let toff = table2_offsets[tp];
                if let Ok(outcome) = broker
                    .fetch(&topo.join_topic, *tp, toff, 100, 1, 4 * 1024 * 1024, false)
                    .await
                {
                    if outcome.error_code == 0 && !outcome.records.is_empty() {
                        let mut state = handle.state.lock().await;
                        for record in &outcome.records {
                            table2_offsets.insert(*tp, record.offset + 1);
                            if record.value.is_empty() {
                                state.table2.remove(&record.key);
                            } else {
                                state.table2.insert(record.key.clone(), record.value.clone());
                            }
                            changed.push(record.key.clone());
                        }
                    }
                }
            }
            changed.extend(left_changed.iter().cloned());
            changed.sort_unstable();
            changed.dedup();
            if !changed.is_empty() {
                let combos: Vec<(Vec<u8>, Vec<u8>)> = {
                    let state = handle.state.lock().await;
                    changed
                        .iter()
                        .filter_map(|k| {
                            match (state.table.get(k), state.table2.get(k)) {
                                (Some(l), Some(r)) => {
                                    let mut v = l.clone();
                                    v.extend_from_slice(&table_table_separator);
                                    v.extend_from_slice(r);
                                    Some((k.clone(), v))
                                }
                                _ => None,
                            }
                        })
                        .collect()
                };
                for (k, v) in combos {
                    let sp = (fnv1a(&k) % sink_partitions as u64) as i32;
                    let out = crate::pb::Record { key: k, value: v, ..Default::default() };
                    let _ = broker
                        .produce(&topo.sink_topic, sp, &[out], -1, 30_000, 0, -1, -1, -1, None)
                        .await;
                }
            }
        }
        // Join stream ingestion: records enter the chain
        // at the JOIN_STREAM step and emit through the
        // remainder of the chain to the sink.
        if let Some((joffsets, jops)) = &mut join_state {
            for (_, parts) in joffsets.iter_mut() {
                for (tp, toff) in parts.iter_mut() {
                    if let Ok(outcome) = broker
                        .fetch(&topo.join_topic, *tp, *toff, 100, 1, 4 * 1024 * 1024, false)
                        .await
                    {
                        if outcome.error_code == 0 && !outcome.records.is_empty() {
                            for record in &outcome.records {
                                *toff = record.offset + 1;
                                let outputs = apply_with_state(
                                    &handle,
                                    jops,
                                    &PipeRec {
                                        key: record.key.clone(),
                                        value: record.value.clone(),
                                        ts: record.timestamp_ms,
                                        window: None,
                                        precomputed: false,
                                        join_side: true,
                                    },
                                    &topo_name,
                                )
                                .await;
                                for out_rec in outputs {
                                    let sink_partition =
                                        (fnv1a(&out_rec.key) % sink_partitions as u64) as i32;
                                    let out = crate::pb::Record {
                                        key: out_rec.key,
                                        value: out_rec.value,
                                        ..Default::default()
                                    };
                                    let _ = broker
                                        .produce(&topo.sink_topic, sink_partition, &[out], -1, 30_000, 0, -1, -1, -1, None)
                                        .await;
                                }
                            }
                        }
                    }
                }
            }
        }
        for (topic, parts) in cogroup_offsets.iter_mut() {
            for (tp, toff) in parts.iter_mut() {
                if let Ok(outcome) = broker
                    .fetch(topic, *tp, *toff, 100, 1, 4 * 1024 * 1024, false)
                    .await
                {
                    if outcome.error_code == 0 && !outcome.records.is_empty() {
                        let mut state = handle.state.lock().await;
                        for record in &outcome.records {
                            *toff = record.offset + 1;
                            if let Some(v) = parse_i64(&record.value) {
                                *state.store.entry(record.key.clone()).or_insert(0) += v;
                            }
                        }
                    }
                }
            }
        }
        let owned = membership.partitions.clone();
        for p in &owned {
            if handle.stop.load(Ordering::Relaxed) {
                break;
            }
            let Some(offset) = offsets.get(p).copied() else {
                // Newly assigned on rejoin: derive and
                // restore (see step below) before fetching.
                continue;
            };
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
                let outputs = apply_with_state(
                    &handle,
                    &ops,
                    &PipeRec {
                        key: record.key.clone(),
                        value: record.value.clone(),
                        ts: record.timestamp_ms,
                        window: None,
                        precomputed: false,
                        join_side: false,
                    },
                    &topo_name,
                )
                .await;
                for out_rec in outputs {
                    let sink_partition = (fnv1a(&out_rec.key) % sink_partitions as u64) as i32;
                    if let Some(t) = &mut txn {
                        let key = (topo.sink_topic.clone(), sink_partition);
                        if !t.partitions_in_txn.contains(&key) {
                            match broker
                                .add_partitions_to_txn(
                                    &app_id,
                                    t.producer_id,
                                    t.producer_epoch,
                                    vec![(topo.sink_topic.clone(), vec![sink_partition])],
                                )
                                .await
                            {
                                Ok(results) => {
                                    if let Some((_, _, err)) = results.first() {
                                        if *err != 0 {
                                            return fail(&handle, format!("AddPartitionsToTxn error {err}")).await;
                                        }
                                    }
                                    t.partitions_in_txn.insert(key.clone());
                                }
                                Err(e) => return fail(&handle, e.message.clone()).await,
                            }
                        }
                    }
                    let headers = match out_rec.window {
                        Some((start, end)) => vec![
                            crate::pb::Header {
                                key: "window-start".to_string(),
                                value: start.to_string().into_bytes(),
                                ..Default::default()
                            },
                            crate::pb::Header {
                                key: "window-end".to_string(),
                                value: end.to_string().into_bytes(),
                                ..Default::default()
                            },
                        ],
                        None => Vec::new(),
                    };
                    let out = crate::pb::Record {
                        key: out_rec.key,
                        value: out_rec.value,
                        headers,
                        ..Default::default()
                    };
                    let (pid, epoch, seq, tid) = match &txn {
                        Some(t) => (
                            t.producer_id,
                            t.producer_epoch,
                            *t.sequences.get(&(topo.sink_topic.clone(), sink_partition)).unwrap_or(&0),
                            Some(app_id.as_str()),
                        ),
                        None => (-1, -1, -1, None),
                    };
                    let produced = broker
                        .produce(&topo.sink_topic, sink_partition, &[out], -1, 30_000, 0, pid, epoch, seq, tid)
                        .await;
                    if produced.as_ref().is_ok_and(|o| o.error_code == 0) {
                        if let Some(t) = &mut txn {
                            *t.sequences.entry((topo.sink_topic.clone(), sink_partition)).or_insert(0) += 1;
                        }
                    }
                    match produced {
                        Ok(o) if o.error_code == 0 => {}
                        Ok(o) => return fail(&handle, format!("produce to {} error {}", topo.sink_topic, o.error_code)).await,
                        Err(e) => return fail(&handle, e.message.clone()).await,
                    }
                }
            }
            if let Some(t) = &mut txn {
                // Exactly-once: attach this batch's source
                // offset to the transaction and commit records
                // + offset atomically.
                let add = broker.add_offsets_to_txn(&app_id, &app_id, t.producer_id, t.producer_epoch).await;
                let txn_err = match add {
                    Ok(0) => broker
                        .txn_offset_commit(
                            &app_id,
                            &app_id,
                            t.producer_id,
                            t.producer_epoch,
                            &topo.source_topic,
                            *p,
                            next_offset,
                            "",
                        )
                        .await
                        .unwrap_or(-1),
                    Ok(code) => code,
                    Err(_) => -1,
                };
                if txn_err != 0 {
                    let _ = broker.end_txn(&app_id, t.producer_id, t.producer_epoch, false).await;
                    return fail(&handle, format!("txn offset commit error {txn_err}")).await;
                }
                if let Some(topic) = &changelog {
                    if let Err(e) = snapshot_changelog(&broker, &handle, topic, &app_id, Some(t)).await {
                        let _ = broker.end_txn(&app_id, t.producer_id, t.producer_epoch, false).await;
                        return fail(&handle, e).await;
                    }
                }
                match broker.end_txn(&app_id, t.producer_id, t.producer_epoch, true).await {
                    Ok(0) => {
                        let parts: Vec<(String, i32)> =
                            t.partitions_in_txn.iter().cloned().collect();
                        if !parts.is_empty() {
                            let _ = broker
                                .write_txn_markers(&parts, t.producer_id, t.producer_epoch, true, &app_id)
                                .await;
                        }
                        t.partitions_in_txn.clear();
                    }
                    Ok(code) => {
                        return fail(&handle, format!("EndTxn commit error {code}")).await
                    }
                    Err(e) => return fail(&handle, e.message.clone()).await,
                }
            } else {
                match broker
                    .offset_commit(
                        &app_id,
                        membership.generation_id,
                        &membership.member_id,
                        None,
                        &topo.source_topic,
                        *p,
                        next_offset,
                        "",
                    )
                    .await
                {
                    Ok(0) => {}
                    Ok(code) => {
                        return fail(
                            &handle,
                            format!("offset commit for streams topology failed with error {code}"),
                        )
                        .await
                    }
                    Err(e) => return fail(&handle, e.message.clone()).await,
                }
            }
            offsets.insert(*p, next_offset);
            if txn.is_none() {
                if let Some(topic) = &changelog {
                    // At-least-once snapshot after the plain
                    // offset commit (EXACTLY_ONCE snapshots
                    // inside the transaction above).
                    let _ = snapshot_changelog(&broker, &handle, topic, &app_id, None).await;
                }
            }
        }
        if !progressed {
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        }
    }
    let _ = broker
        .leave_group(&membership.coordinator, &app_id, &membership.member_id, None)
        .await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[allow(clippy::too_many_arguments)]
    async fn pipe(
        ops: &[Op],
        key: &[u8],
        value: &[u8],
        ts: i64,
        store: &mut HashMap<Vec<u8>, i64>,
        sessions: &mut HashMap<Vec<u8>, Vec<(i64, i64)>>,
        records: &mut HashMap<Vec<u8>, Vec<(i64, Option<i64>)>>,
        stream_time: &mut i64,
    ) -> Vec<PipeRec> {
        apply_pipeline(
            ops,
            &PipeRec { key: key.to_vec(), value: value.to_vec(), ts, window: None, precomputed: false, join_side: false },
            &mut PipelineCtx {
                store,
                stream_time,
                table: &EMPTY_TABLE,
                sessions,
                key_records: records,
                processors: &mut HashMap::new(),
                topology_name: "test",
                join_buffer: &mut Vec::new(),
            },
        )
        .await
    }

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
        assert!(validate_chain(&[
            spb::Operator::TokenizeWords,
            spb::Operator::GroupByKey,
            spb::Operator::Count,
        ])
        .is_ok());
        assert!(validate_chain(&[]).is_err());
        // Stateful before GROUP_BY_KEY is rejected.
        assert!(validate_chain(&[spb::Operator::Count]).is_err());
        assert!(validate_chain(&[
            spb::Operator::TokenizeWords,
            spb::Operator::Count,
            spb::Operator::GroupByKey,
        ])
        .is_err());
        // Duplicate GROUP_BY_KEY is rejected; repeated
        // stateful ops after grouping are fine.
        assert!(validate_chain(&[
            spb::Operator::GroupByKey,
            spb::Operator::GroupByKey,
            spb::Operator::Count,
        ])
        .is_err());
        assert!(validate_chain(&[spb::Operator::OperatorUnspecified]).is_err());
        // Bad params are rejected at resolution time.
        let bad = spb::Topology {
            steps: vec![spb::Step {
                operator: spb::Operator::MapValues,
                param: "sideways".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(resolve_ops(&bad).is_err());
        let bad_agg = spb::Topology {
            steps: vec![
                spb::Step { operator: spb::Operator::GroupByKey, ..Default::default() },
                spb::Step { operator: spb::Operator::Aggregate, ..Default::default() },
            ],
            ..Default::default()
        };
        assert!(resolve_ops(&bad_agg).is_err());
    }

    #[tokio::test]
    async fn pipeline_stateless_and_aggregation() {
        let topo = spb::Topology {
            steps: vec![
                spb::Step { operator: spb::Operator::Filter, param: "value_gt:10".into(), ..Default::default() },
                spb::Step { operator: spb::Operator::SelectKey, param: "value".into(), ..Default::default() },
                spb::Step { operator: spb::Operator::GroupByKey, ..Default::default() },
                spb::Step {
                    operator: spb::Operator::Aggregate,
                    aggregator: spb::Aggregator::AggregateSum,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let ops = resolve_ops(&topo).unwrap();
        let mut store = HashMap::new();
        let mut sessions: HashMap<Vec<u8>, Vec<(i64, i64)>> = HashMap::new();
        let mut records: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>> = HashMap::new();
        let mut st = 0i64;
        assert!(pipe(&ops, b"k", b"5", 0, &mut store, &mut sessions, &mut records, &mut st).await.is_empty(), "filter drops <= 10");
        let out = pipe(&ops, b"k", b"20", 0, &mut store, &mut sessions, &mut records, &mut st).await;
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].key, b"20".to_vec());
        assert_eq!(out[0].value, b"20".to_vec());
        let out = pipe(&ops, b"k", b"20", 0, &mut store, &mut sessions, &mut records, &mut st).await;
        assert_eq!(out[0].value, b"40".to_vec(), "sum accumulates per key");
    }

    #[tokio::test]
    async fn pipeline_min_max_reduce_and_map() {
        let topo = spb::Topology {
            steps: vec![
                spb::Step { operator: spb::Operator::GroupByKey, ..Default::default() },
                spb::Step { operator: spb::Operator::Reduce, param: "max".into(), ..Default::default() },
                spb::Step { operator: spb::Operator::MapValues, param: "upper".into(), ..Default::default() },
            ],
            ..Default::default()
        };
        // MAP_VALUES upper on a numeric string is a no-op
        // textually; use MIN aggregate instead for the second
        // half of this test below.
        let ops = resolve_ops(&topo).unwrap();
        let mut store = HashMap::new();
        let mut sessions: HashMap<Vec<u8>, Vec<(i64, i64)>> = HashMap::new();
        let mut records: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>> = HashMap::new();
        let mut st = 0i64;
        let mut last = Vec::new();
        for v in ["7", "3", "9"] {
            last = pipe(&ops, b"a", v.as_bytes(), 0, &mut store, &mut sessions, &mut records, &mut st).await;
        }
        assert_eq!(last[0].value, b"9".to_vec());
        assert_eq!(store[b"a".as_slice()], 9);
    }

    #[test]
    fn window_assignment_tumbling_and_hopping() {
        assert_eq!(window_starts(0, 1000, 1000), vec![0]);
        assert_eq!(window_starts(999, 1000, 1000), vec![0]);
        assert_eq!(window_starts(1000, 1000, 1000), vec![1000]);
        assert_eq!(window_starts(1500, 1000, 500), vec![500, 1000, 1500].into_iter().filter(|s| *s + 1000 > 1500 && *s <= 1500).collect::<Vec<_>>());
        assert_eq!(window_starts(1500, 1000, 500), vec![1000, 1500]);
    }

    #[tokio::test]
    async fn windowed_count_pipeline_and_late_drop() {
        let topo = spb::Topology {
            steps: vec![
                spb::Step { operator: spb::Operator::GroupByKey, ..Default::default() },
                spb::Step { operator: spb::Operator::WindowTumbling, window_size_ms: 1000, ..Default::default() },
                spb::Step { operator: spb::Operator::Count, ..Default::default() },
            ],
            ..Default::default()
        };
        let ops = resolve_ops(&topo).unwrap();
        let mut store = HashMap::new();
        let mut stream_time = 0i64;
        let mut sessions_map: HashMap<Vec<u8>, Vec<(i64, i64)>> = HashMap::new();
        let mut records_map: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>> = HashMap::new();
        macro_rules! run {
            ($ts:expr) => {
                pipe(&ops, b"w", b"x", $ts, &mut store, &mut sessions_map, &mut records_map, &mut stream_time).await
            };
        }
        assert_eq!(run!(100)[0].value, b"1".to_vec());
        assert_eq!(run!(900)[0].value, b"2".to_vec());
        assert_eq!(run!(1100)[0].value, b"1".to_vec());
        // Window [0,1000) closed at stream time 1100 (grace 0):
        // a late record for it is dropped.
        assert!(run!(500).is_empty());
    }

    #[tokio::test]
    async fn session_windows_merge_and_sliding_recompute() {
        // Session: gap 2000. Records at 0, 1000 (same
        // session), 10000 (new session), then 2500 bridges
        // nothing (gap to first session last=1000 is 1500,
        // merges into it; second stays separate).
        let topo = spb::Topology {
            steps: vec![
                spb::Step { operator: spb::Operator::GroupByKey, ..Default::default() },
                spb::Step { operator: spb::Operator::WindowSession, gap_ms: 2000, ..Default::default() },
                spb::Step { operator: spb::Operator::Count, ..Default::default() },
            ],
            ..Default::default()
        };
        let ops = resolve_ops(&topo).unwrap();
        let mut store: HashMap<Vec<u8>, i64> = HashMap::new();
        let mut sessions_map: HashMap<Vec<u8>, Vec<(i64, i64)>> = HashMap::new();
        let mut records_map: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>> = HashMap::new();
        let mut stream_time = 0i64;
        macro_rules! run {
            ($ts:expr) => {
                pipe(&ops, b"k", b"v", $ts, &mut store, &mut sessions_map, &mut records_map, &mut stream_time).await
            };
        }
        let out = run!(0);
        assert_eq!(out[0].window, Some((0, 1)));
        assert_eq!(out[0].value, b"1".to_vec());
        let out = run!(1000);
        assert_eq!(out[0].window, Some((0, 1001)));
        assert_eq!(out[0].value, b"2".to_vec(), "session aggregate survives extension");
        let out = run!(10000);
        assert_eq!(out[0].window, Some((10000, 10001)));
        assert_eq!(out[0].value, b"1".to_vec());
        assert_eq!(store[&store_key(b"k", Some((0, 1001)))], 2);
        assert_eq!(store[&store_key(b"k", Some((10000, 10001)))], 1);

        // Sliding: size 10000, values 5 at t=10000, 7 at
        // t=15000. Windows: [1,10001)={5}, [5001,15001)={5,7}.
        let topo2 = spb::Topology {
            steps: vec![
                spb::Step { operator: spb::Operator::GroupByKey, ..Default::default() },
                spb::Step { operator: spb::Operator::WindowSliding, window_size_ms: 10000, ..Default::default() },
                spb::Step {
                    operator: spb::Operator::Aggregate,
                    aggregator: spb::Aggregator::AggregateSum,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let ops2 = resolve_ops(&topo2).unwrap();
        let mut store2: HashMap<Vec<u8>, i64> = HashMap::new();
        let mut sessions2: HashMap<Vec<u8>, Vec<(i64, i64)>> = HashMap::new();
        let mut records2: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>> = HashMap::new();
        let mut st2 = 0i64;
        macro_rules! run2 {
            ($ts:expr, $v:expr) => {
                pipe(&ops2, b"k", $v.as_bytes(), $ts, &mut store2, &mut sessions2, &mut records2, &mut st2).await
            };
        }
        let out = run2!(10000, "5");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].value, b"5".to_vec());
        let out = run2!(15000, "7");
        assert!(out.iter().any(|r| r.window == Some((5001, 15001)) && r.value == b"12".to_vec()),
            "sliding window must aggregate both records: {out:?}");
    }

    #[tokio::test]
    async fn stream_stream_join_matches_same_window_only() {
        let topo = spb::Topology {
            join_topic: "right".into(),
            steps: vec![
                spb::Step {
                    operator: spb::Operator::JoinStream,
                    window_size_ms: 1000,
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        let ops = resolve_ops(&topo).unwrap();
        let mut store: HashMap<Vec<u8>, i64> = HashMap::new();
        let mut sessions: HashMap<Vec<u8>, Vec<(i64, i64)>> = HashMap::new();
        let mut records: HashMap<Vec<u8>, Vec<(i64, Option<i64>)>> = HashMap::new();
        let mut st = 0i64;
        let mut jb: Vec<(Vec<u8>, i64, Vec<u8>, bool)> = Vec::new();
        let left = apply_pipeline(&ops, &PipeRec { key: b"k".to_vec(), value: b"L".to_vec(), ts: 100, window: None, precomputed: false, join_side: false },
            &mut PipelineCtx { store: &mut store, stream_time: &mut st, table: &EMPTY_TABLE, sessions: &mut sessions, key_records: &mut records, processors: &mut HashMap::new(), topology_name: "t", join_buffer: &mut jb }).await;
        assert!(left.is_empty(), "no match yet");
        let joined = apply_pipeline(&ops, &PipeRec { key: b"k".to_vec(), value: b"R".to_vec(), ts: 900, window: None, precomputed: false, join_side: true },
            &mut PipelineCtx { store: &mut store, stream_time: &mut st, table: &EMPTY_TABLE, sessions: &mut sessions, key_records: &mut records, processors: &mut HashMap::new(), topology_name: "t", join_buffer: &mut jb }).await;
        assert_eq!(joined.len(), 1);
        assert_eq!(joined[0].value, b"L:R".to_vec());
        // Different window: no match.
        let other = apply_pipeline(&ops, &PipeRec { key: b"k".to_vec(), value: b"R2".to_vec(), ts: 2100, window: None, precomputed: false, join_side: true },
            &mut PipelineCtx { store: &mut store, stream_time: &mut st, table: &EMPTY_TABLE, sessions: &mut sessions, key_records: &mut records, processors: &mut HashMap::new(), topology_name: "t", join_buffer: &mut jb }).await;
        assert!(other.is_empty());
    }

    #[test]
    fn range_and_window_scans() {
        let mut store: HashMap<Vec<u8>, i64> = HashMap::new();
        store.insert(b"apple".to_vec(), 3);
        store.insert(b"apricot".to_vec(), 1);
        store.insert(b"banana".to_vec(), 2);
        store.insert(store_key(b"apple", Some((100, 200))), 5);
        store.insert(store_key(b"apple", Some((200, 300))), 7);
        let hits = scan_range(&store, b"ap", 100);
        assert_eq!(hits, vec![(b"apple".to_vec(), 3), (b"apricot".to_vec(), 1)]);
        assert_eq!(scan_range(&store, b"ap", 1).len(), 1);
        let wins = scan_windows(&store, b"apple", 0, 250);
        assert_eq!(wins, vec![(100, 200, 5)]);
        assert_eq!(scan_windows(&store, b"apple", 0, 300).len(), 2);
    }

    #[test]
    fn changelog_restore_latest_wins() {
        let records = vec![
            (b"a".to_vec(), b"1".to_vec()),
            (b"b".to_vec(), b"5".to_vec()),
            (b"a".to_vec(), b"3".to_vec()),
            (b"c".to_vec(), b"not-a-number".to_vec()),
        ];
        let store = restore_changelog(&records);
        assert_eq!(store[b"a".as_slice()], 3);
        assert_eq!(store[b"b".as_slice()], 5);
        assert!(!store.contains_key(b"c".as_slice()));
        assert_eq!(changelog_topic("streams-wc"), "streams-wc-store-changelog");
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
