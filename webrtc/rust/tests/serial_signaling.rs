//! Headless signaling (serial/BLE-style byte stream) end to end,
//! plus the embedded sleep/wake cycle: a peer that goes silent is
//! surfaced by consent expiry, and on wake the devices re-signal
//! over the same kind of link and media flows again.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::{ChannelHandle, DcEndpoint, EndpointEvent};
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::signaling::{read_signal, write_signal, SignalMessage};
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// One end of an in-memory byte stream (stands in for a UART or
/// BLE link): bytes written at one end are read at the other.
struct PipeEnd {
    tx: mpsc::Sender<Vec<u8>>,
    rx: mpsc::Receiver<Vec<u8>>,
    buf: Vec<u8>,
    pos: usize,
}

fn pipe_pair() -> (PipeEnd, PipeEnd) {
    let (tx1, rx1) = mpsc::channel();
    let (tx2, rx2) = mpsc::channel();
    (
        PipeEnd { tx: tx1, rx: rx2, buf: Vec::new(), pos: 0 },
        PipeEnd { tx: tx2, rx: rx1, buf: Vec::new(), pos: 0 },
    )
}

impl Read for PipeEnd {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.buf.len() {
            match self.rx.recv() {
                Ok(chunk) => {
                    self.buf = chunk;
                    self.pos = 0;
                }
                Err(_) => return Ok(0), // peer closed: EOF
            }
        }
        let n = (self.buf.len() - self.pos).min(out.len());
        out[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

impl Write for PipeEnd {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.tx
            .send(data.to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "pipe closed"))?;
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

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

fn expect_signal(io: &mut PipeEnd) -> SignalMessage {
    read_signal(io).expect("read signal").expect("stream open")
}

fn send_candidates(peer: &Peer, io: &mut PipeEnd) {
    for line in peer.local_candidate_lines() {
        write_signal(io, &SignalMessage::Candidate(line)).unwrap();
    }
    write_signal(io, &SignalMessage::EndOfCandidates).unwrap();
}

fn recv_candidates(peer: &mut Peer, io: &mut PipeEnd) {
    loop {
        match expect_signal(io) {
            SignalMessage::Candidate(line) => {
                peer.add_remote_candidate(&line);
            }
            SignalMessage::EndOfCandidates => break,
            other => panic!("expected candidate traffic, got {:?}", other),
        }
    }
}

/// Connect two peers exchanging SDP + candidates ONLY through
/// the framed byte stream. Offerer runs on this thread, the
/// answerer on a spawned one.
fn connect_over_serial(
    mut offerer: Peer,
    mut answerer: Peer,
    mut offerer_io: PipeEnd,
    mut answerer_io: PipeEnd,
) -> (DcEndpoint, DcEndpoint) {
    let answerer_thread = std::thread::spawn(move || {
        let offer = match expect_signal(&mut answerer_io) {
            SignalMessage::Offer(sdp) => sdp,
            other => panic!("expected offer, got {:?}", other),
        };
        let answer = answerer.handle_offer(&offer).expect("handle offer");
        write_signal(&mut answerer_io, &SignalMessage::Answer(answer)).unwrap();
        send_candidates(&answerer, &mut answerer_io);
        recv_candidates(&mut answerer, &mut answerer_io);
        answerer.connect().expect("answerer connect")
    });

    let offer = offerer.create_offer();
    write_signal(&mut offerer_io, &SignalMessage::Offer(offer)).unwrap();
    let answer = match expect_signal(&mut offerer_io) {
        SignalMessage::Answer(sdp) => sdp,
        other => panic!("expected answer, got {:?}", other),
    };
    offerer.handle_answer(&answer).expect("handle answer");
    send_candidates(&offerer, &mut offerer_io);
    recv_candidates(&mut offerer, &mut offerer_io);
    let offerer_ep = offerer.connect().expect("offerer connect");
    let answerer_ep = answerer_thread.join().unwrap();
    (offerer_ep, answerer_ep)
}

fn echo_roundtrip(
    a_ep: &DcEndpoint,
    b_ep: &DcEndpoint,
    a_channel: &ChannelHandle,
    b_channel: &mut Option<ChannelHandle>,
    msg: &[u8],
) {
    a_channel.send_binary(msg).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut echoed = false;
    while Instant::now() < deadline && !echoed {
        if let Some(event) = b_ep.recv_event_timeout(Duration::from_millis(100)) {
            match event {
                EndpointEvent::ChannelOpened { channel } => {
                    *b_channel = Some(channel);
                }
                EndpointEvent::Message { data, .. } => {
                    assert_eq!(data, msg);
                    let mut reply = b"echo:".to_vec();
                    reply.extend_from_slice(&data);
                    b_channel.as_ref().unwrap().send_binary(&reply).unwrap();
                    echoed = true;
                }
                _ => {}
            }
        }
    }
    assert!(echoed, "answerer never saw the message");
    let mut expected = b"echo:".to_vec();
    expected.extend_from_slice(msg);
    let mut got = false;
    while Instant::now() < deadline && !got {
        if let Some(EndpointEvent::Message { data, .. }) =
            a_ep.recv_event_timeout(Duration::from_millis(100))
        {
            assert_eq!(data, expected);
            got = true;
        }
    }
    assert!(got, "offerer never saw the echo");
}

#[test]
fn peers_connect_over_serial_signaling() {
    let (a_io, b_io) = pipe_pair();
    let (a_ep, b_ep) = connect_over_serial(loopback_peer(), loopback_peer(), a_io, b_io);
    let channel = a_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    let mut b_channel = None;
    echo_roundtrip(&a_ep, &b_ep, &channel, &mut b_channel, b"over-serial");
}

#[test]
fn sleep_wake_reconnects_over_serial() {
    // Phase 1: connect over the serial link with tight consent
    // timers so the "sleep" is observable quickly.
    let (fail_tx, fail_rx) = mpsc::channel::<()>();
    let mut device_a = loopback_peer();
    device_a.set_consent(
        Some(Duration::from_millis(100)),
        Duration::from_millis(800),
        move || {
            let _ = fail_tx.send(());
        },
    );
    let (a_io, b_io) = pipe_pair();
    let (a_ep, b_ep) = connect_over_serial(device_a, loopback_peer(), a_io, b_io);
    let channel = a_ep
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    let mut b_channel = None;
    echo_roundtrip(&a_ep, &b_ep, &channel, &mut b_channel, b"before-sleep");

    // Sleep: the remote device powers off — its endpoint shuts
    // down, its side of the link goes silent. Consent expiry
    // must surface the loss on the awake side.
    drop(b_channel);
    b_ep.shutdown();
    fail_rx
        .recv_timeout(Duration::from_secs(10))
        .expect("consent failure fires when the peer sleeps");
    drop(channel);
    drop(a_ep);

    // Wake: the device boots, both sides create fresh peers and
    // re-signal over a fresh serial link (the woken device
    // initiates this time). Media flows again.
    let (a_io2, b_io2) = pipe_pair();
    let (b_ep2, a_ep2) = connect_over_serial(loopback_peer(), loopback_peer(), b_io2, a_io2);
    let channel2 = b_ep2
        .open_channel(ChannelParams { label: "echo".into(), ..Default::default() })
        .unwrap();
    let mut a_channel2 = None;
    echo_roundtrip(&b_ep2, &a_ep2, &channel2, &mut a_channel2, b"after-wake");
}
