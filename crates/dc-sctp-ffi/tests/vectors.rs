//! Conformance: fixtures/sctp_vectors.json (the shared
//! fragment-delivery scenarios all three mirrored stacks
//! run) executed entirely through the C ABI functions.

use dc_sctp_ffi::*;

const CAP: usize = 1 << 20;

fn read_packets(buf: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        let len = u32::from_be_bytes(buf[pos..pos + 4].try_into().unwrap()) as usize;
        pos += 4;
        out.push(buf[pos..pos + len].to_vec());
        pos += len;
    }
    out
}

struct Ev {
    kind: u8,
    stream: u16,
    payload: Vec<u8>,
}

fn read_events(buf: &[u8]) -> Vec<Ev> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        let kind = buf[pos];
        let stream = u16::from_be_bytes(buf[pos + 1..pos + 3].try_into().unwrap());
        let len = u32::from_be_bytes(buf[pos + 7..pos + 11].try_into().unwrap()) as usize;
        pos += 11;
        out.push(Ev {
            kind,
            stream,
            payload: buf[pos..pos + len].to_vec(),
        });
        pos += len;
    }
    out
}

struct Assoc(*mut GrpcdcSctp);

impl Assoc {
    fn client() -> Self {
        Assoc(grpcdc_sctp_new_client(5000, 5000))
    }
    fn server() -> Self {
        Assoc(grpcdc_sctp_new_server(5000, 5000))
    }
    fn handle(&self, packet: &[u8], now: u64) -> (Vec<Vec<u8>>, Vec<Ev>) {
        let mut pbuf = vec![0u8; CAP];
        let mut ebuf = vec![0u8; CAP];
        let mut elen: usize = 0;
        let n = grpcdc_sctp_handle_packet(
            self.0,
            packet.as_ptr(),
            packet.len(),
            now,
            pbuf.as_mut_ptr(),
            CAP,
            ebuf.as_mut_ptr(),
            CAP,
            &mut elen,
        );
        assert!(n >= 0, "handle_packet rc={n}");
        pbuf.truncate(n as usize);
        ebuf.truncate(elen);
        (read_packets(&pbuf), read_events(&ebuf))
    }
    fn send(&self, stream: u16, payload: &[u8], now: u64) -> Vec<Vec<u8>> {
        let mut buf = vec![0u8; CAP];
        let n = grpcdc_sctp_send_data(
            self.0,
            stream,
            63,
            payload.as_ptr(),
            payload.len(),
            0,
            -1,
            -1,
            now,
            buf.as_mut_ptr(),
            CAP,
        );
        assert!(n >= 0, "send_data rc={n}");
        buf.truncate(n as usize);
        read_packets(&buf)
    }
}

impl Drop for Assoc {
    fn drop(&mut self) {
        grpcdc_sctp_free(self.0);
    }
}

fn handshake(client: &Assoc, server: &Assoc, now: u64) {
    let mut ibuf = vec![0u8; CAP];
    let n = grpcdc_sctp_connect(client.0, now, ibuf.as_mut_ptr(), CAP);
    assert!(n > 0, "connect rc={n}");
    ibuf.truncate(n as usize);
    let (replies, _) = server.handle(&ibuf, now);
    let (replies, _) = client.handle(&replies[0], now);
    for p in &replies {
        let (replies, _) = server.handle(p, now);
        for q in &replies {
            client.handle(q, now);
        }
    }
    assert_eq!(grpcdc_sctp_is_established(client.0), 1);
    assert_eq!(grpcdc_sctp_is_established(server.0), 1);
}

#[test]
fn ffi_sctp_vectors() {
    let raw = std::fs::read_to_string("../../fixtures/sctp_vectors.json")
        .expect("fixtures/sctp_vectors.json");
    let doc: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let now = 0u64;
    for sc in doc["scenarios"].as_array().unwrap() {
        let name = sc["name"].as_str().unwrap();
        let stream = sc["stream"].as_u64().unwrap() as u16;
        let client = Assoc::client();
        let server = Assoc::server();
        handshake(&client, &server, now);
        let mut packets = Vec::new();
        let mut want: Vec<Vec<u8>> = Vec::new();
        for m in sc["messages"].as_array().unwrap() {
            let size = m["size"].as_u64().unwrap() as usize;
            let fill = m["fill"].as_str().unwrap().as_bytes()[0];
            let payload = vec![fill; size];
            want.push(payload.clone());
            packets.extend(client.send(stream, &payload, now));
        }
        let mut got: Vec<Vec<u8>> = Vec::new();
        for idx in sc["deliver"].as_array().unwrap() {
            let (_, events) = server.handle(&packets[idx.as_u64().unwrap() as usize], now);
            for ev in events {
                if ev.kind == 2 {
                    assert_eq!(ev.stream, stream, "{name}: stream");
                    got.push(ev.payload);
                }
            }
        }
        let expect: Vec<Vec<u8>> = sc["expect"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| want[i.as_u64().unwrap() as usize].clone())
            .collect();
        assert_eq!(got, expect, "scenario {name}");
        let mut stats = [0u64; 7];
        assert_eq!(grpcdc_sctp_stats(server.0, stats.as_mut_ptr()), 0);
        assert!(
            stats[3] >= got.len() as u64,
            "{name}: chunks_received {stats:?}"
        );
    }
}
