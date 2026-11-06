//! grpc-dc messages over raw Ethernet II frames (EthFraming):
//! fragmentation/reassembly of whole wire messages with no IP,
//! UDP, or ICE — the bare-metal transport path where the target
//! supplies only a NIC driver.

use dc_webrtc::net::{EthFraming, EthernetCable, ETHERTYPE_GRPC_DC};
use std::sync::Arc;
use std::time::Duration;

const MAC_A: [u8; 6] = [0x02, 0, 0, 0, 0, 1];
const MAC_B: [u8; 6] = [0x02, 0, 0, 0, 0, 2];

fn msg_pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i % 251) as u8).collect()
}

#[test]
fn framing_round_trip_small_and_empty() {
    let mut tx = EthFraming::new(MAC_A, MAC_B);
    let mut rx = EthFraming::new(MAC_B, MAC_A);
    for msg in [b"hello".to_vec(), Vec::new(), vec![7u8; 1491]] {
        let mut frames = Vec::new();
        tx.encode(&msg, &mut frames);
        assert_eq!(frames.len(), 1);
        let out = rx.input(&frames[0]).expect("single-fragment message");
        assert_eq!(out, msg);
    }
}

#[test]
fn framing_fragments_large_message() {
    let mut tx = EthFraming::new(MAC_A, MAC_B);
    let mut rx = EthFraming::new(MAC_B, MAC_A);
    let msg = msg_pattern(100_000);
    let mut frames = Vec::new();
    tx.encode(&msg, &mut frames);
    assert!(frames.len() > 60, "expected many fragments, got {}", frames.len());
    for frame in &frames {
        assert!(frame.len() <= 1514, "frame too large: {}", frame.len());
        let (_, _, ethertype, _) = dc_webrtc::net::ethernet_parse(frame).unwrap();
        assert_eq!(ethertype, ETHERTYPE_GRPC_DC);
    }
    let mut got = None;
    for frame in &frames {
        got = rx.input(frame).or(got);
    }
    assert_eq!(got.unwrap(), msg);
}

#[test]
fn framing_drops_on_gap_and_resynchronizes() {
    let mut tx = EthFraming::new(MAC_A, MAC_B);
    let mut rx = EthFraming::new(MAC_B, MAC_A);
    let mut frames = Vec::new();
    tx.encode(&msg_pattern(5000), &mut frames);
    assert!(frames.len() >= 3);
    // Lose the middle fragment: no message may surface.
    assert!(rx.input(&frames[0]).is_none());
    assert!(rx.input(&frames[2]).is_none());
    // The next message reassembles cleanly.
    let mut frames2 = Vec::new();
    tx.encode(b"next", &mut frames2);
    assert_eq!(rx.input(&frames2[0]).unwrap(), b"next");
}

#[test]
fn framing_ignores_foreign_frames() {
    let mut tx = EthFraming::new(MAC_A, MAC_B);
    let mut rx = EthFraming::new(MAC_B, MAC_A);
    let other = dc_webrtc::net::ethernet_frame(
        MAC_B,
        MAC_A,
        dc_webrtc::net::ETHERTYPE_IPV4,
        b"not grpc",
    );
    assert!(rx.input(&other).is_none());
    let mut frames = Vec::new();
    tx.encode(b"ours", &mut frames);
    assert_eq!(rx.input(&frames[0]).unwrap(), b"ours");
}

#[test]
fn framing_over_virtual_cable_both_directions() {
    let cable = Arc::new(EthernetCable::new());
    let port_a = cable.raw_endpoint(MAC_A);
    let port_b = cable.raw_endpoint(MAC_B);
    let mut fa = EthFraming::new(MAC_A, MAC_B);
    let mut fb = EthFraming::new(MAC_B, MAC_A);

    // A -> B: 64 KiB message.
    let big = msg_pattern(65_536);
    let mut frames = Vec::new();
    fa.encode(&big, &mut frames);
    for frame in frames {
        port_a.send_frame(frame);
    }
    let mut got = None;
    while got.is_none() {
        let frame = port_b.recv_frame(Duration::from_secs(2)).expect("cable frame");
        got = fb.input(&frame);
    }
    assert_eq!(got.unwrap(), big);

    // B -> A: small reply.
    let mut frames = Vec::new();
    fb.encode(b"reply", &mut frames);
    for frame in frames {
        port_b.send_frame(frame);
    }
    let frame = port_a.recv_frame(Duration::from_secs(2)).expect("cable frame");
    assert_eq!(fa.input(&frame).unwrap(), b"reply");
}
