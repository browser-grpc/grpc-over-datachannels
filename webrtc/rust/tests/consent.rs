//! Consent freshness (RFC 7675): agent-level expiry accounting,
//! plus a peer-level check that a healthy pair never fires the
//! failure callback. (The end-to-end dead-peer surfacing is
//! covered in the Go and JS suites, whose peers own their
//! sockets after connect; here the demux thread keeps answering
//! for the life of the process, so expiry logic is asserted at
//! the agent layer.)

use dc_webrtc::ice::{Candidate, IceAgent};
use dc_webrtc::peer::{Peer, PeerConfig};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::mpsc::channel;
use std::time::Duration;

fn addr(port: u16) -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port)
}

fn nominated_pair() -> (IceAgent, IceAgent) {
    let mut offerer = IceAgent::new(true);
    let mut answerer = IceAgent::new(false);
    offerer.local_candidates = vec![Candidate::host(addr(40001), "1")];
    answerer.local_candidates = vec![Candidate::host(addr(40002), "1")];
    offerer.set_remote(
        &answerer.local_ufrag.clone(),
        &answerer.local_pwd.clone(),
        answerer.local_candidates.clone(),
    );
    answerer.set_remote(
        &offerer.local_ufrag.clone(),
        &offerer.local_pwd.clone(),
        offerer.local_candidates.clone(),
    );
    answerer.controlling = false;
    // Pump checks/responses until both sides nominate.
    for _ in 0..50 {
        if offerer.nominated.is_some() && answerer.nominated.is_some() {
            return (offerer, answerer);
        }
        for (bytes, dest) in offerer.due_checks() {
            let (responses, _) = answerer.handle_stun(&bytes, addr(40001));
            for (resp, rdest) in responses {
                let _ = rdest;
                offerer.handle_stun(&resp, dest);
            }
        }
        for (bytes, dest) in answerer.due_checks() {
            let (responses, _) = offerer.handle_stun(&bytes, addr(40002));
            for (resp, rdest) in responses {
                let _ = rdest;
                answerer.handle_stun(&resp, dest);
            }
        }
    }
    panic!("agents never nominated");
}

#[test]
fn consent_expires_without_responses_and_refreshes_with_them() {
    let (mut offerer, mut answerer) = nominated_pair();
    assert!(!offerer.consent_expired(Duration::from_secs(30)));

    // No consent traffic: a short expiry lapses.
    std::thread::sleep(Duration::from_millis(120));
    assert!(offerer.consent_expired(Duration::from_millis(50)));

    // One consent round-trip refreshes consent.
    let (bytes, dest) = offerer.consent_check().expect("consent check");
    let (responses, _) = answerer.handle_stun(&bytes, addr(40001));
    assert_eq!(responses.len(), 1);
    offerer.handle_stun(&responses[0].0, dest);
    assert!(!offerer.consent_expired(Duration::from_millis(50)));
}

#[test]
fn consent_check_before_nomination_is_none() {
    let mut agent = IceAgent::new(true);
    assert!(agent.consent_check().is_none());
    assert!(!agent.consent_expired(Duration::from_millis(1)));
}

#[test]
fn healthy_pair_never_fires_consent_failure() {
    fn loopback_peer() -> Peer {
        Peer::new(PeerConfig {
            local_ips: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            require_peer_certificate: true,
            stun_servers: Vec::new(),
            turn_servers: Vec::new(),
        })
        .unwrap()
    }
    let mut offerer = loopback_peer();
    let mut answerer = loopback_peer();
    let (tx, rx) = channel::<()>();
    offerer.set_consent(
        Some(Duration::from_millis(100)),
        Duration::from_millis(800),
        move || {
            let _ = tx.send(());
        },
    );
    let offer = offerer.create_offer();
    let answer = answerer.handle_offer(&offer).unwrap();
    offerer.handle_answer(&answer).unwrap();
    let answerer_thread = std::thread::spawn(move || answerer.connect());
    let _offerer_ep = offerer.connect().expect("offerer connect");
    let _answerer_ep = answerer_thread.join().unwrap().expect("answerer connect");

    // Consent checks (100 ms) are answered; no failure may fire.
    assert!(
        rx.recv_timeout(Duration::from_millis(1800)).is_err(),
        "consent failure fired on a healthy pair"
    );
}
