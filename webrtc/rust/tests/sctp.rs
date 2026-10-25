//! SCTP state machine tests over a simulated link (deterministic clock,
//! optional packet drops) — no sockets involved.

use dc_webrtc::sctp::{Association, Event, SendOptions};

struct Link {
    client: Association,
    server: Association,
    now: u64,
}

impl Link {
    fn new() -> Self {
        Self {
            client: Association::new_client(5000, 5000),
            server: Association::new_server(5000, 5000),
            now: 0,
        }
    }

    fn deliver_to_server(&mut self, packets: Vec<Vec<u8>>) -> Vec<Event> {
        let mut events = Vec::new();
        for p in packets {
            let (replies, ev) = self.server.handle_packet(&p, self.now);
            events.extend(ev);
            // SACK-clocked sends (cwnd) deliver via this nested
            // call; its events are part of the same exchange.
            events.extend(self.deliver_to_client(replies));
        }
        events
    }

    fn deliver_to_client(&mut self, packets: Vec<Vec<u8>>) -> Vec<Event> {
        let mut events = Vec::new();
        for p in packets {
            let (replies, ev) = self.client.handle_packet(&p, self.now);
            events.extend(ev);
            if !replies.is_empty() {
                events.extend(self.deliver_to_server(replies));
            }
        }
        events
    }

    fn handshake(&mut self) {
        let init = self.client.connect(self.now);
        let server_events = self.deliver_to_server(vec![init]);
        // Nested delivery (SACK-clocked sends) can surface the
        // client's Connected event here; no Data may flow yet.
        assert!(
            !server_events.iter().any(|e| matches!(e, Event::Data { .. })),
            "no data events during handshake: {server_events:?}"
        );
        assert!(self.client.is_established(), "client should be established");
        assert!(self.server.is_established(), "server should be established");
    }

    fn client_send(
        &mut self,
        stream: u16,
        ppid: u32,
        payload: &[u8],
        opts: SendOptions,
    ) -> Vec<Event> {
        let packets = self.client.send_data(stream, ppid, payload, opts, self.now);
        self.deliver_to_server(packets)
    }
}

#[test]
fn handshake_and_ordered_data() {
    let mut link = Link::new();
    link.handshake();
    let events = link.client_send(0, 63, b"hello sctp", SendOptions::default());
    assert_eq!(
        events,
        vec![Event::Data { stream: 0, ppid: 63, payload: b"hello sctp".to_vec() }]
    );
}

#[test]
fn fragmented_message_reassembles() {
    let mut link = Link::new();
    link.handshake();
    let payload: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
    let events = link.client_send(3, 54, &payload, SendOptions::default());
    assert_eq!(events.len(), 1);
    match &events[0] {
        Event::Data { stream, ppid, payload: got } => {
            assert_eq!(*stream, 3);
            assert_eq!(*ppid, 54);
            assert_eq!(got, &payload);
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn ordered_streams_are_independent() {
    let mut link = Link::new();
    link.handshake();
    let mut events = Vec::new();
    events.extend(link.client_send(0, 63, b"s0-a", SendOptions::default()));
    events.extend(link.client_send(1, 63, b"s1-a", SendOptions::default()));
    events.extend(link.client_send(0, 63, b"s0-b", SendOptions::default()));
    let payloads: Vec<&[u8]> = events
        .iter()
        .map(|e| match e {
            Event::Data { payload, .. } => payload.as_slice(),
            _ => panic!("unexpected {e:?}"),
        })
        .collect();
    assert_eq!(payloads, vec![b"s0-a".as_slice(), b"s1-a".as_slice(), b"s0-b".as_slice()]);
}

#[test]
fn unordered_delivery() {
    let mut link = Link::new();
    link.handshake();
    let events = link.client_send(
        0,
        63,
        b"unordered",
        SendOptions { unordered: true, ..Default::default() },
    );
    assert_eq!(events.len(), 1);
}

#[test]
fn loss_and_rto_retransmit() {
    let mut link = Link::new();
    link.handshake();
    let packets = link.client.send_data(0, 63, b"lost once", SendOptions::default(), link.now);
    assert!(!packets.is_empty());
    // Drop everything: nothing arrives.
    let events = link.deliver_to_server(vec![]);
    assert!(events.is_empty());
    // Advance past the RTO; the client retransmits.
    link.now += 1500;
    let (retransmitted, _) = link.client.tick(link.now);
    assert!(!retransmitted.is_empty(), "expected retransmission after RTO");
    let events = link.deliver_to_server(retransmitted);
    assert_eq!(events.len(), 1);
}

#[test]
fn partial_reliability_abandons_and_unblocks_stream() {
    let mut link = Link::new();
    link.handshake();
    // Message 1 on stream 0 will be "lost" (never delivered) and is
    // allowed zero retransmits; message 2 must not be stuck behind it.
    let doomed = link.client.send_data(
        0,
        63,
        b"doomed",
        SendOptions { max_retransmits: Some(0), ..Default::default() },
        link.now,
    );
    let _ = doomed; // dropped on purpose
    let second = link.client.send_data(0, 63, b"survivor", SendOptions::default(), link.now);
    let events_before = link.deliver_to_server(second);
    // Ordered delivery: survivor waits behind the missing first message.
    assert!(events_before.is_empty(), "survivor must wait: {events_before:?}");
    // Tick: doomed is past its first (and only) transmission, gets
    // abandoned, FORWARD-TSN releases the stream.
    link.now += 1500;
    let (mut tick_packets, _) = link.client.tick(link.now);
    // tick also retransmits survivor (unacked); deliver everything.
    let events = link.deliver_to_server(tick_packets.split_off(0));
    let payloads: Vec<Vec<u8>> = events
        .iter()
        .filter_map(|e| match e {
            Event::Data { payload, .. } => Some(payload.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(payloads, vec![b"survivor".to_vec()]);
}

#[test]
fn shutdown_handshake() {
    let mut link = Link::new();
    link.handshake();
    let packets = link.client.close(link.now);
    let server_events = link.deliver_to_server(packets);
    assert!(server_events.contains(&Event::Closed));
    assert!(!link.client.is_established());
}
