//! Full-peer echo with headless signaling: SDP and candidates
//! travel as framed messages (see `signaling`) over the process's
//! stdin/stdout byte stream instead of files or a WebSocket.
//! Point it at a serial device or BLE stream by swapping the
//! stdio handles for the device handles — nothing else changes:
//!
//!   peer_serial offerer   (signals out on stdout, in on stdin)
//!   peer_serial answerer
//!
//! The offerer opens the "echo" channel and echoes stdin lines
//! (prefixed like peer_echo's file-based harness).

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::endpoint::EndpointEvent;
use dc_webrtc::peer::{Peer, PeerConfig};
use dc_webrtc::signaling::{read_signal, write_signal, SignalMessage};
use std::io::{self, BufRead, Read, Write};
use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

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

struct Stdio {
    input: io::Stdin,
    output: io::Stdout,
}

impl Read for Stdio {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.input.read(buf)
    }
}

impl Write for Stdio {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.output.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.output.flush()
    }
}

fn expect(io: &mut Stdio) -> io::Result<SignalMessage> {
    read_signal(io)?.ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "signaling closed"))
}

fn send_candidates(peer: &Peer, io: &mut Stdio) -> io::Result<()> {
    for line in peer.local_candidate_lines() {
        write_signal(io, &SignalMessage::Candidate(line))?;
    }
    write_signal(io, &SignalMessage::EndOfCandidates)
}

fn recv_candidates(peer: &mut Peer, io: &mut Stdio) -> io::Result<()> {
    loop {
        match expect(io)? {
            SignalMessage::Candidate(line) => {
                peer.add_remote_candidate(&line);
            }
            SignalMessage::EndOfCandidates => return Ok(()),
            other => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("expected candidate traffic, got {:?}", other),
                ))
            }
        }
    }
}

fn main() -> io::Result<()> {
    let mode = std::env::args().nth(1).unwrap_or_default();
    let mut sig = Stdio { input: io::stdin(), output: io::stdout() };
    match mode.as_str() {
        "answerer" => {
            let mut peer = loopback_peer();
            let offer = match expect(&mut sig)? {
                SignalMessage::Offer(sdp) => sdp,
                other => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("expected offer, got {:?}", other),
                    ))
                }
            };
            let answer = peer.handle_offer(&offer)?;
            write_signal(&mut sig, &SignalMessage::Answer(answer))?;
            send_candidates(&peer, &mut sig)?;
            recv_candidates(&mut peer, &mut sig)?;
            let endpoint = peer.connect()?;
            eprintln!("CONNECTED");
            let mut channels = std::collections::HashMap::new();
            loop {
                match endpoint.recv_event_timeout(Duration::from_secs(120)) {
                    Some(EndpointEvent::ChannelOpened { channel }) => {
                        eprintln!("CHANNEL_OPEN stream={}", channel.stream);
                        channels.insert(channel.stream, channel);
                    }
                    Some(EndpointEvent::Message { stream, data, .. }) => {
                        if let Some(channel) = channels.get(&stream) {
                            let mut reply = b"re:".to_vec();
                            reply.extend_from_slice(&data);
                            channel.send_binary(&reply)?;
                        }
                    }
                    Some(EndpointEvent::ChannelClosed { stream }) => {
                        eprintln!("CHANNEL_CLOSED stream={stream}");
                        channels.remove(&stream);
                    }
                    None => return Ok(()),
                    _ => {}
                }
            }
        }
        "offerer" => {
            let mut peer = loopback_peer();
            let offer = peer.create_offer();
            write_signal(&mut sig, &SignalMessage::Offer(offer))?;
            let answer = match expect(&mut sig)? {
                SignalMessage::Answer(sdp) => sdp,
                other => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("expected answer, got {:?}", other),
                    ))
                }
            };
            peer.handle_answer(&answer)?;
            send_candidates(&peer, &mut sig)?;
            recv_candidates(&mut peer, &mut sig)?;
            let endpoint = peer.connect()?;
            eprintln!("CONNECTED");
            let channel = endpoint.open_channel(ChannelParams {
                label: "echo".into(),
                ..Default::default()
            })?;
            let stdin = io::stdin();
            // Signaling is finished; stdin now carries chat lines.
            // Note: in this demo the same stdin served signaling, so
            // lines are read through a fresh lock after the framed
            // exchange (frames are consumed exactly).
            for line in stdin.lock().lines() {
                let line = line?;
                if line.is_empty() {
                    continue;
                }
                channel.send_binary(line.as_bytes())?;
                match endpoint.recv_event_timeout(Duration::from_secs(15)) {
                    Some(EndpointEvent::Message { data, .. }) => {
                        // Replies go to stderr: stdout is the
                        // signaling stream and stays frame-clean.
                        eprintln!("{}", String::from_utf8_lossy(&data));
                    }
                    _ => {
                        eprintln!("no reply");
                        std::process::exit(1);
                    }
                }
            }
            Ok(())
        }
        _ => {
            eprintln!("usage: peer_serial <offerer|answerer>");
            std::process::exit(2);
        }
    }
}
