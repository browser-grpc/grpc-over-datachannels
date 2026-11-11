//! C ABI over `KafkaService` (cdylib): embed the Kafka
//! client in-process from any language with a stdlib FFI.
//!
//! Calls take a method name (`"CreateTopics"`, `"Produce"`,
//! `"Consume"`, ...) and the protobuf-encoded request, and
//! return the protobuf-encoded response — the exact bytes the
//! gRPC service would exchange — so per-language wrappers stay
//! thin: generated message types plus five functions.
//!
//! - `kafka_native_new(broker, client_id)` -> handle (NULL on error)
//! - `kafka_native_free(handle)`
//! - `kafka_native_call(handle, method, req, len, &out, &out_len)`
//!   -> 0 ok, -1 error (`kafka_native_last_error()` has text)
//! - `kafka_native_stream_new(handle, method, req, len)` -> stream
//! - `kafka_native_stream_next(stream, &out, &out_len)`
//!   -> 1 item, 0 end, -1 error
//! - `kafka_native_stream_free(stream)`
//! - `kafka_native_bytes_free(ptr, len)` frees out buffers
//!
//! SASL/TLS are available through `kafka_native_new_v2`
//! and its `KafkaNativeConfig` struct.

use crate::client::KafkaConfig;
use crate::service::KafkaService;
use crate::stub::Kafka;
use futures_util::StreamExt;
use grpc_dc::{CallCtx, Message, Status};
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::Arc;

pub struct KafkaHandle {
    rt: tokio::runtime::Runtime,
    service: Arc<KafkaService>,
}

pub struct StreamHandle {
    rx: std::sync::mpsc::Receiver<Result<Vec<u8>, String>>,
}

thread_local! {
    static LAST_ERROR: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

fn set_error(msg: &str) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = CString::new(msg.replace('\0', " ")).unwrap_or_default();
    });
}

fn fail<T>(msg: &str, val: T) -> T {
    set_error(msg);
    val
}

/// # Safety
/// `ptr`/`len` must come from `kafka_native_call`,
/// `kafka_native_stream_next`, or be null.
unsafe fn take_out(bytes: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    unsafe {
        *out = ptr;
        *out_len = len;
    }
}

fn ctx(method: &str) -> CallCtx {
    CallCtx::detached(format!("/grpcdc.kafka.v1.Kafka/{method}"))
}

fn cstr<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err("null string argument".to_string());
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|e| format!("invalid utf8: {e}"))
}

fn bytes<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        return &[];
    }
    unsafe { std::slice::from_raw_parts(p, len) }
}

async fn dispatch_unary(
    svc: &KafkaService,
    method: &str,
    req: &[u8],
) -> Result<Vec<u8>, Status> {
    macro_rules! unary {
        ($m:ident, $Req:ident) => {{
            let r = crate::pb::$Req::decode(req)?;
            let resp = Kafka::$m(svc, r, ctx(method)).await?;
            Ok(resp.encode())
        }};
    }
    match method {
        "Metadata" => unary!(metadata, MetadataRequest),
        "OpenProducer" => unary!(open_producer, OpenProducerRequest),
        "CloseProducer" => unary!(close_producer, CloseProducerRequest),
        "EndTransaction" => unary!(end_transaction, EndTransactionRequest),
        "Produce" => unary!(produce, ProduceRequest),
        "ListOffsets" => unary!(list_offsets, ListOffsetsRequest),
        "CommitOffset" => unary!(commit_offset, CommitOffsetRequest),
        "FetchOffset" => unary!(fetch_offset, FetchOffsetRequest),
        "CreateTopics" => unary!(create_topics, CreateTopicsRequest),
        "DeleteTopics" => unary!(delete_topics, DeleteTopicsRequest),
        "DescribeConfigs" => unary!(describe_configs, DescribeConfigsRequest),
        "AlterConfigs" => unary!(alter_configs, AlterConfigsRequest),
        "CreatePartitions" => unary!(create_partitions, CreatePartitionsRequest),
        "DeleteRecords" => unary!(delete_records, DeleteRecordsRequest),
        "ListGroups" => unary!(list_groups, ListGroupsRequest),
        "DescribeGroups" => unary!(describe_groups, DescribeGroupsRequest),
        "DeleteGroups" => unary!(delete_groups, DeleteGroupsRequest),
        "DeleteGroupOffsets" => unary!(delete_group_offsets, DeleteGroupOffsetsRequest),
        "DescribeAcls" => unary!(describe_acls, DescribeAclsRequest),
        "CreateAcls" => unary!(create_acls, CreateAclsRequest),
        "DeleteAcls" => unary!(delete_acls, DeleteAclsRequest),
        "ListTransactions" => unary!(list_transactions, ListTransactionsRequest),
        "DescribeTransactions" => unary!(describe_transactions, DescribeTransactionsRequest),
        other => Err(Status::invalid_argument(format!(
            "kafka ffi: unknown or streaming method {other}"
        ))),
    }
}

/// Full client configuration for `kafka_native_new_v2`.
/// All string fields are C strings or NULL. `sasl_mechanism`
/// is NULL (no SASL), "PLAIN", "SCRAM-SHA-256", or
/// "SCRAM-SHA-512". TLS is enabled when `tls_ca_cert` is set
/// or `tls_insecure_skip_verify` is nonzero.
#[repr(C)]
pub struct KafkaNativeConfig {
    pub broker: *const c_char,
    pub client_id: *const c_char,
    pub sasl_mechanism: *const c_char,
    pub username: *const c_char,
    pub password: *const c_char,
    pub tls_ca_cert: *const c_char,
    pub tls_server_name: *const c_char,
    pub tls_insecure_skip_verify: i32,
}

fn build_handle(cfg: KafkaConfig) -> *mut KafkaHandle {
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => return fail(&format!("kafka ffi runtime: {e}"), std::ptr::null_mut()),
    };
    let service = Arc::new(KafkaService::new(cfg));
    Box::into_raw(Box::new(KafkaHandle { rt, service }))
}

fn opt_cstr(p: *const c_char) -> Result<Option<String>, String> {
    if p.is_null() {
        Ok(None)
    } else {
        Ok(Some(cstr(p)?.to_string()))
    }
}

/// # Safety
/// `cfg` must point to a valid `KafkaNativeConfig` whose
/// string fields are valid C strings or NULL.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_new_v2(cfg: *const KafkaNativeConfig) -> *mut KafkaHandle {
    let cfg = match unsafe { cfg.as_ref() } {
        Some(c) => c,
        None => return fail("kafka ffi: null config", std::ptr::null_mut()),
    };
    let broker = match cstr(cfg.broker) {
        Ok(s) => s.to_string(),
        Err(e) => return fail(&e, std::ptr::null_mut()),
    };
    let client_id = match opt_cstr(cfg.client_id) {
        Ok(s) => s.unwrap_or_else(|| "grpc-dc-kafka-client".to_string()),
        Err(e) => return fail(&e, std::ptr::null_mut()),
    };
    let (username, password) = match (opt_cstr(cfg.username), opt_cstr(cfg.password)) {
        (Ok(u), Ok(p)) => (u, p),
        (Err(e), _) | (_, Err(e)) => return fail(&e, std::ptr::null_mut()),
    };
    let sasl = match opt_cstr(cfg.sasl_mechanism) {
        Ok(None) => None,
        Ok(Some(mech)) => {
            let (Some(user), Some(pass)) = (username, password) else {
                return fail(
                    "kafka ffi: sasl_mechanism requires username and password",
                    std::ptr::null_mut(),
                );
            };
            match mech.as_str() {
                "PLAIN" => Some(crate::client::SaslConfig::Plain {
                    username: user,
                    password: pass,
                }),
                "SCRAM-SHA-256" | "SCRAM-SHA-512" => Some(crate::client::SaslConfig::Scram {
                    mechanism: mech,
                    username: user,
                    password: pass,
                }),
                other => {
                    return fail(
                        &format!("kafka ffi: unknown sasl mechanism {other}"),
                        std::ptr::null_mut(),
                    )
                }
            }
        }
        Err(e) => return fail(&e, std::ptr::null_mut()),
    };
    let (tls_ca_cert, tls_server_name) =
        match (opt_cstr(cfg.tls_ca_cert), opt_cstr(cfg.tls_server_name)) {
            (Ok(a), Ok(b)) => (a, b),
            (Err(e), _) | (_, Err(e)) => return fail(&e, std::ptr::null_mut()),
        };
    let tls = if tls_ca_cert.is_some() || cfg.tls_insecure_skip_verify != 0 {
        Some(crate::client::TlsConfig {
            ca_cert: tls_ca_cert,
            server_name: tls_server_name,
            insecure_skip_verify: cfg.tls_insecure_skip_verify != 0,
        })
    } else {
        None
    };
    build_handle(KafkaConfig {
        broker,
        client_id,
        sasl,
        tls,
    })
}

/// # Safety
/// `broker` and `client_id` must be valid C strings or null
/// (null client_id means the default).
#[no_mangle]
pub unsafe extern "C" fn kafka_native_new(
    broker: *const c_char,
    client_id: *const c_char,
) -> *mut KafkaHandle {
    let broker = match cstr(broker) {
        Ok(s) => s.to_string(),
        Err(e) => return fail(&e, std::ptr::null_mut()),
    };
    let client_id = if client_id.is_null() {
        "grpc-dc-kafka-client".to_string()
    } else {
        match cstr(client_id) {
            Ok(s) => s.to_string(),
            Err(e) => return fail(&e, std::ptr::null_mut()),
        }
    };
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => return fail(&format!("kafka ffi runtime: {e}"), std::ptr::null_mut()),
    };
    let service = Arc::new(KafkaService::new(KafkaConfig {
        broker,
        client_id,
        sasl: None,
        tls: None,
    }));
    Box::into_raw(Box::new(KafkaHandle { rt, service }))
}

/// # Safety
/// `handle` must come from `kafka_native_new` and be unused
/// afterwards.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_free(handle: *mut KafkaHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

/// # Safety
/// `handle` must be a live handle; `method` a valid C string;
/// `req`/`req_len` a valid byte slice; `out`/`out_len` valid
/// out pointers. Free `*out` with `kafka_native_bytes_free`.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_call(
    handle: *mut KafkaHandle,
    method: *const c_char,
    req: *const u8,
    req_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let handle = match unsafe { handle.as_ref() } {
        Some(h) => h,
        None => return fail("kafka ffi: null handle", -1),
    };
    let method = match cstr(method) {
        Ok(s) => s.to_string(),
        Err(e) => return fail(&e, -1),
    };
    let req = bytes(req, req_len).to_vec();
    match handle
        .rt
        .block_on(dispatch_unary(&handle.service, &method, &req))
    {
        Ok(resp) => {
            unsafe { take_out(resp, out, out_len) };
            0
        }
        Err(e) => fail(&format!("{e:?}"), -1),
    }
}

/// # Safety
/// Same contract as `kafka_native_call`. The returned stream
/// must be freed with `kafka_native_stream_free`.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_stream_new(
    handle: *mut KafkaHandle,
    method: *const c_char,
    req: *const u8,
    req_len: usize,
) -> *mut StreamHandle {
    let handle = match unsafe { handle.as_ref() } {
        Some(h) => h,
        None => return fail("kafka ffi: null handle", std::ptr::null_mut()),
    };
    let method = match cstr(method) {
        Ok(s) => s.to_string(),
        Err(e) => return fail(&e, std::ptr::null_mut()),
    };
    let req = bytes(req, req_len).to_vec();
    let svc = handle.service.clone();
    let opened: Result<
        futures_util::stream::BoxStream<'static, Result<Vec<u8>, Status>>,
        Status,
    > = handle.rt.block_on(async move {
        match method.as_str() {
            "Consume" => {
                let r = crate::pb::ConsumeRequest::decode(&req)?;
                Kafka::consume(&*svc, r, ctx(&method))
                    .await
                    .map(|s| s.map(|i| i.map(|m| m.encode())).boxed())
            }
            "Subscribe" => {
                let r = crate::pb::GroupSubscribeRequest::decode(&req)?;
                Kafka::subscribe(&*svc, r, ctx(&method))
                    .await
                    .map(|s| s.map(|i| i.map(|m| m.encode())).boxed())
            }
            other => Err(Status::invalid_argument(format!(
                "kafka ffi: not a streaming method {other}"
            ))),
        }
    });
    let mut stream = match opened {
        Ok(s) => s,
        Err(e) => return fail(&format!("{e:?}"), std::ptr::null_mut()),
    };
    let (tx, rx) = std::sync::mpsc::channel::<Result<Vec<u8>, String>>();
    handle.rt.spawn(async move {
        while let Some(item) = stream.next().await {
            let sent = match item {
                Ok(bytes) => tx.send(Ok(bytes)),
                Err(e) => tx.send(Err(format!("{e:?}"))),
            };
            if sent.is_err() {
                break;
            }
        }
    });
    Box::into_raw(Box::new(StreamHandle { rx }))
}

/// # Safety
/// `stream` must be a live stream; `out`/`out_len` valid out
/// pointers.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_stream_next(
    stream: *mut StreamHandle,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let stream = match unsafe { stream.as_ref() } {
        Some(s) => s,
        None => return fail("kafka ffi: null stream", -1),
    };
    match stream.rx.recv() {
        Ok(Ok(bytes)) => {
            unsafe { take_out(bytes, out, out_len) };
            1
        }
        Ok(Err(e)) => fail(&e, -1),
        Err(_) => 0,
    }
}

/// # Safety
/// `stream` must come from `kafka_native_stream_new` and be
/// unused afterwards.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_stream_free(stream: *mut StreamHandle) {
    if !stream.is_null() {
        unsafe {
            drop(Box::from_raw(stream));
        }
    }
}

/// # Safety
/// `ptr`/`len` must come from a successful call/stream_next.
#[no_mangle]
pub unsafe extern "C" fn kafka_native_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Vec::from_raw_parts(ptr, len, len));
        }
    }
}

/// Last error text for this thread (empty when none). The
/// pointer is valid until the next FFI call on this thread.
#[no_mangle]
pub extern "C" fn kafka_native_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[allow(dead_code)]
fn _assert_send(handle: &KafkaHandle) {
    fn is_send<T: Send>() {}
    is_send::<KafkaHandle>();
    let _ = handle as *const KafkaHandle as *const c_void;
}
