//! Stack tracing: Peer::connect emits ice.nominated,
//! dtls.handshake, and endpoint.ready to the registered
//! observer; dormant (and harmless) with none, and a panicking
//! observer cannot break the connection.

use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::trace::{set_observer, TraceEvent};
use dc_webrtc::x509::Certificate;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex};

fn config(cert: Certificate) -> PeerConfig {
    PeerConfig {
        local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
        require_peer_certificate: true,
        certificate: Some(cert),
        session_resumption: false,
        session_ticket_key: None,
        resume_session: None,
        stun_servers: Vec::new(),
        turn_servers: Vec::new(),
    }
}

fn connect_pair() {
    let offerer = Peer::new(config(Certificate::generate_self_signed("offerer"))).unwrap();
    let answerer = Peer::new(config(Certificate::generate_self_signed("answerer"))).unwrap();
    let mut offerer = offerer;
    let mut answerer = answerer;
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).expect("handle offer");
    offerer.handle_answer(&answer).expect("handle answer");
    let t = std::thread::spawn(move || answerer.connect());
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = t.join().unwrap().expect("answerer connect");
    offerer_ep.shutdown();
    answerer_ep.shutdown();
}

// One test only: the observer is process-global, so parallel
// tests in this binary would observe each other's events.
#[test]
fn connect_emits_stack_events() {
    let events: Arc<Mutex<Vec<TraceEvent>>> = Arc::new(Mutex::new(Vec::new()));
    let sink = events.clone();
    set_observer(Some(Arc::new(move |e: &TraceEvent| {
        sink.lock().unwrap().push(e.clone());
    })));
    connect_pair();
    set_observer(None);
    let events = events.lock().unwrap();
    // Both peers connect: two of each event.
    for name in ["ice.nominated", "dtls.handshake", "endpoint.ready"] {
        assert_eq!(
            events.iter().filter(|e| e.name == name).count(),
            2,
            "two {name} events in {events:?}"
        );
    }
    assert!(events
        .iter()
        .filter(|e| e.name == "dtls.handshake")
        .all(|e| e.detail == "full"));
    let details: Vec<&str> = events
        .iter()
        .filter(|e| e.name == "endpoint.ready")
        .map(|e| e.detail.as_str())
        .collect();
    assert!(details.contains(&"client") && details.contains(&"server"), "{details:?}");
    drop(events);

    // Dormant and panicking observers are both safe.
    set_observer(None);
    connect_pair();
    set_observer(Some(Arc::new(|_| panic!("observer blew up"))));
    connect_pair();
    set_observer(None);
}
