//! DataChannel close via SCTP stream reset (RFC 6525): both
//! sides observe ChannelClosed, a second channel keeps working,
//! and a reset with a TSN gap in flight is deferred.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::sctp::{Association, Event, SCTP_PORT};
use std::net::{IpAddr, Ipv4Addr};
use std::time::{Duration, Instant};

#[test]
fn channel_close_resets_stream_on_both_sides() {
    fn loopback_peer() -> Peer {
        Peer::new(PeerConfig {
            local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            require_peer_certificate: true,
            certificate: None,
            session_resumption: false,
            session_ticket_key: None,
            resume_session: None,
            stun_servers: Vec::new(),
            turn_servers: Vec::new(),
        })
        .unwrap()
    }
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    let ch1 = offerer_ep
        .open_channel(ChannelParams { label: "one".into(), ..Default::default() })
        .unwrap();
    ch1.send_binary(b"before-close").unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let (mut got_msg, mut remote_closed) = (false, false);
    while Instant::now() < deadline && !got_msg {
        match answerer_ep.recv_event_timeout(Duration::from_millis(200)) {
            Some(EndpointEvent::Message { data, .. }) => {
                assert_eq!(data, b"before-close");
                got_msg = true;
            }
            Some(EndpointEvent::ChannelClosed { .. }) => remote_closed = true,
            _ => {}
        }
    }
    assert!(got_msg);

    ch1.close();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut local_closed = false;
    while Instant::now() < deadline && !(local_closed && remote_closed) {
        if let Some(EndpointEvent::ChannelClosed { .. }) =
            offerer_ep.recv_event_timeout(Duration::from_millis(50))
        {
            local_closed = true;
        }
        if let Some(EndpointEvent::ChannelClosed { .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(50))
        {
            remote_closed = true;
        }
    }
    assert!(local_closed, "closing side never completed");
    assert!(remote_closed, "remote side never saw the close");

    // The association survives: a second channel still works.
    let ch2 = offerer_ep
        .open_channel(ChannelParams { label: "two".into(), ..Default::default() })
        .unwrap();
    ch2.send_binary(b"after-close").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut got2 = false;
    while Instant::now() < deadline && !got2 {
        if let Some(EndpointEvent::Message { data, .. }) =
            answerer_ep.recv_event_timeout(Duration::from_millis(200))
        {
            assert_eq!(data, b"after-close");
            got2 = true;
        }
    }
    assert!(got2, "second channel broken after first closed");
}

#[test]
fn reset_defers_until_cumulative() {
    let mut client = Association::new_client(SCTP_PORT, SCTP_PORT);
    let mut server = Association::new_server(SCTP_PORT, SCTP_PORT);
    fn exchange(assoc: &mut Association, packets: Vec<Vec<u8>>) -> (Vec<Vec<u8>>, Vec<Event>) {
        let mut out = Vec::new();
        let mut events = Vec::new();
        for p in packets {
            let (o, e) = assoc.handle_packet(&p, 0);
            out.extend(o);
            events.extend(e);
        }
        (out, events)
    }
    let init = client.connect(0);
    let (ack, _) = exchange(&mut server, vec![init]);
    let (echo, _) = exchange(&mut client, ack);
    let (ack2, _) = exchange(&mut server, echo);
    exchange(&mut client, ack2);
    assert!(client.is_established() && server.is_established());

    const PPID_BINARY: u32 = 53;
    let pkts1 = client.send_data(0, PPID_BINARY, b"first", Default::default(), 0);
    let pkts2 = client.send_data(0, PPID_BINARY, b"second", Default::default(), 0);
    let (mut resps, events) = exchange(&mut server, pkts1);
    exchange(&mut client, resps.clone());
    assert!(
        matches!(&events[..], [Event::Data { payload, .. }] if payload == b"first"),
        "events: {events:?}"
    );

    let reset = client.close_stream(0);
    let (resps1, events) = exchange(&mut server, reset);
    resps = resps1;
    assert!(
        !events.iter().any(|e| matches!(e, Event::StreamReset { .. })),
        "reset fired across a TSN gap"
    );

    // The deferred reset applies once the gap fills; the server
    // auto-resets its outgoing side in the same exchange.
    let (resps2, events) = exchange(&mut server, pkts2);
    resps.extend(resps2);
    assert!(
        events.iter().any(|e| matches!(e, Event::Data { payload, .. } if payload == b"second")),
        "second message missing"
    );

    let (client_pkts, client_events) = exchange(&mut client, resps);
    assert!(
        client_events.iter().any(|e| matches!(e, Event::StreamReset { .. })),
        "client never completed the close"
    );
    let (_, events) = exchange(&mut server, client_pkts);
    assert!(
        events.iter().any(|e| matches!(e, Event::StreamReset { .. })),
        "server never completed the reset after gap filled"
    );
}
