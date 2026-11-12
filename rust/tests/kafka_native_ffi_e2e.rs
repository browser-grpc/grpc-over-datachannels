//! C ABI coverage for `kafka-native`: error paths (mostly
//! broker-free), Subscribe through the ABI, and the
//! mid-stream `stream_free` cancel path that must not poison
//! the pooled broker connection for the next call.
//!
//! Broker legs need KAFKA_PROXY_E2E_BROKER=host:port; the
//! error-path tests always run.

use kafka_native::ffi::*;
use std::ffi::{c_char, CString};
use std::ptr;

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

unsafe fn last_error() -> String {
    let p = kafka_native_last_error();
    if p.is_null() {
        return String::new();
    }
    unsafe { std::ffi::CStr::from_ptr(p as *const c_char) }
        .to_string_lossy()
        .into_owned()
}

unsafe fn new_handle(broker: &str) -> *mut KafkaHandle {
    let b = CString::new(broker).unwrap();
    let c = CString::new("grpc-dc-kafka-ffi-e2e").unwrap();
    let h = unsafe { kafka_native_new(b.as_ptr(), c.as_ptr()) };
    assert!(!h.is_null(), "kafka_native_new failed");
    h
}

unsafe fn call(
    h: *mut KafkaHandle,
    method: &str,
    req: &[u8],
) -> Result<Vec<u8>, String> {
    let m = CString::new(method).unwrap();
    let mut out: *mut u8 = ptr::null_mut();
    let mut out_len: usize = 0;
    let rc = unsafe {
        kafka_native_call(
            h,
            m.as_ptr(),
            req.as_ptr(),
            req.len(),
            &mut out,
            &mut out_len,
        )
    };
    if rc != 0 {
        return Err(unsafe { last_error() });
    }
    let data = if out.is_null() {
        Vec::new()
    } else {
        let d = unsafe { std::slice::from_raw_parts(out, out_len) }.to_vec();
        unsafe { kafka_native_bytes_free(out, out_len) };
        d
    };
    Ok(data)
}

#[test]
fn ffi_error_paths() {
    unsafe {
        // Null handle.
        let m = CString::new("Metadata").unwrap();
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = kafka_native_call(
            ptr::null_mut(),
            m.as_ptr(),
            ptr::null(),
            0,
            &mut out,
            &mut out_len,
        );
        assert_eq!(rc, -1);
        assert!(last_error().contains("null handle"), "{}", last_error());

        // Null broker string.
        let h = kafka_native_new(ptr::null(), ptr::null());
        assert!(h.is_null());
        assert!(!last_error().is_empty());

        // Handle to an unreachable broker: construction is
        // lazy, so it succeeds; calls fail with an error.
        let h = new_handle("127.0.0.1:1");

        // Unknown method.
        let err = call(h, "BogusMethod", &[]).unwrap_err();
        assert!(err.contains("BogusMethod"), "{err}");

        // Streaming method via the unary entry point.
        let err = call(h, "Consume", &[]).unwrap_err();
        assert!(err.contains("Consume"), "{err}");

        // Malformed protobuf for a real method.
        let err = call(h, "Produce", &[0xff, 0xff, 0xff]).unwrap_err();
        assert!(!err.is_empty());

        // Unary method via the streaming entry point.
        let m = CString::new("Metadata").unwrap();
        let s = kafka_native_stream_new(h, m.as_ptr(), ptr::null(), 0);
        assert!(s.is_null());
        assert!(last_error().contains("Metadata"), "{}", last_error());

        kafka_native_free(h);
        kafka_native_free(ptr::null_mut()); // must be a no-op
    }
}

#[test]
fn ffi_subscribe_stream() {
    let Some(broker) = broker_or_skip() else { return };
    unsafe {
        use grpc_dc::Message;
        let h = new_handle(&broker);
        let topic = unique_topic("grpc-dc-ffi-sub");
        let group = unique_topic("grpc-dc-ffi-group");
        let req = kafka_native::pb::CreateTopicsRequest {
            topics: vec![kafka_native::pb::NewTopic {
                name: topic.clone(),
                num_partitions: 1,
                replication_factor: 1,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        };
        let resp = call(h, "CreateTopics", &req.encode()).expect("create via ffi");
        let created = kafka_native::pb::CreateTopicsResponse::decode(&resp).unwrap();
        assert_eq!(created.results[0].error_code, 0, "{created:?}");

        let req = kafka_native::pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![kafka_native::pb::Record {
                value: b"sub-one".to_vec(),
                ..Default::default()
            }],
            acks: kafka_native::pb::Acks::AcksAll,
            ..Default::default()
        };
        call(h, "Produce", &req.encode()).expect("produce via ffi");

        let req = kafka_native::pb::GroupSubscribeRequest {
            group_id: group.clone(),
            topics: vec![topic.clone()],
            session_timeout_ms: 30_000,
            max_poll_records: 10,
            auto_offset_reset: "earliest".to_string(),
            ..Default::default()
        };
        let m = CString::new("Subscribe").unwrap();
        let payload = req.encode();
        let s = kafka_native_stream_new(h, m.as_ptr(), payload.as_ptr(), payload.len());
        assert!(!s.is_null(), "subscribe stream_new: {}", last_error());
        // Drain until the produced record arrives (assignment
        // chunks come first), with a bounded number of chunks.
        let mut saw_record = false;
        for _ in 0..30 {
            let mut out: *mut u8 = ptr::null_mut();
            let mut out_len: usize = 0;
            let rc = kafka_native_stream_next(s, &mut out, &mut out_len);
            assert_eq!(rc, 1, "subscribe chunk: {}", last_error());
            let chunk = kafka_native::pb::GroupSubscribeResponse::decode(
                &std::slice::from_raw_parts(out, out_len),
            )
            .unwrap();
            kafka_native_bytes_free(out, out_len);
            if let Some(batch) = &chunk.batch {
                if batch.records.iter().any(|r| r.value == b"sub-one") {
                    saw_record = true;
                    break;
                }
            }
        }
        assert!(saw_record, "produced record never arrived via Subscribe");
        kafka_native_stream_free(s);
        kafka_native_free(h);
    }
}

#[test]
fn ffi_stream_free_mid_stream_keeps_connection() {
    let Some(broker) = broker_or_skip() else { return };
    unsafe {
        let h = new_handle(&broker);
        let topic = unique_topic("grpc-dc-ffi-cancel");
        use grpc_dc::Message;
        // Create topic through the ABI.
        let req = kafka_native::pb::CreateTopicsRequest {
            topics: vec![kafka_native::pb::NewTopic {
                name: topic.clone(),
                num_partitions: 1,
                replication_factor: 1,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        };
        let resp = call(h, "CreateTopics", &req.encode()).expect("create via ffi");
        let created = kafka_native::pb::CreateTopicsResponse::decode(&resp).unwrap();
        assert_eq!(created.results[0].error_code, 0, "{created:?}");

        // Produce one record.
        let req = kafka_native::pb::ProduceRequest {
            topic: topic.clone(),
            partition: 0,
            records: vec![kafka_native::pb::Record {
                value: b"x".to_vec(),
                ..Default::default()
            }],
            acks: kafka_native::pb::Acks::AcksAll,
            ..Default::default()
        };
        let resp = call(h, "Produce", &req.encode()).expect("produce via ffi");
        let produced = kafka_native::pb::ProduceResponse::decode(&resp).unwrap();
        assert_eq!(produced.error_code, 0, "{produced:?}");

        // Consume: read one chunk, then free the stream while
        // the service has a long-poll fetch in flight.
        let req = kafka_native::pb::ConsumeRequest {
            topic: topic.clone(),
            partition: 0,
            offset: -2,
            max_records: 10,
            max_wait_ms: 2_000,
            ..Default::default()
        };
        let m = CString::new("Consume").unwrap();
        let payload = req.encode();
        let s = kafka_native_stream_new(h, m.as_ptr(), payload.as_ptr(), payload.len());
        assert!(!s.is_null(), "stream_new: {}", last_error());
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = kafka_native_stream_next(s, &mut out, &mut out_len);
        assert_eq!(rc, 1, "first chunk: {}", last_error());
        let chunk = kafka_native::pb::ConsumeResponse::decode(
            &std::slice::from_raw_parts(out, out_len),
        )
        .unwrap();
        kafka_native_bytes_free(out, out_len);
        assert_eq!(chunk.records.len(), 1);
        // Let the next long-poll fetch get in flight, then free.
        std::thread::sleep(std::time::Duration::from_millis(300));
        kafka_native_stream_free(s);

        // The next call on this handle must succeed (no stale
        // fetch response, no TOPIC_ALREADY_EXISTS).
        let topic2 = unique_topic("grpc-dc-ffi-after-cancel");
        let req = kafka_native::pb::CreateTopicsRequest {
            topics: vec![kafka_native::pb::NewTopic {
                name: topic2.clone(),
                num_partitions: 1,
                replication_factor: 1,
                ..Default::default()
            }],
            timeout_ms: 30_000,
            ..Default::default()
        };
        let resp = call(h, "CreateTopics", &req.encode()).expect("create after cancel");
        let created = kafka_native::pb::CreateTopicsResponse::decode(&resp).unwrap();
        assert_eq!(created.results[0].error_code, 0, "{created:?}");

        kafka_native_free(h);
    }
}
