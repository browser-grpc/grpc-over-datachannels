//! DataChannel echo harness over direct DTLS (no ICE):
//! `dc_echo server <port>` echoes channel messages; `dc_echo client
//! <port>` opens the "echo" channel, sends stdin lines as binary, and
//! prints replies. Used by Rust/JS cross-tests.

use dc_webrtc::dcep::ChannelParams;
use dc_webrtc::dtls::{Dtls, DtlsConfig, DtlsIo, Role};
use dc_webrtc::endpoint::{DcEndpoint, EndpointEvent};
use dc_webrtc::x509::Certificate;
use std::io::{self, BufRead, Write};
use std::net::{SocketAddr, UdpSocket};
use std::sync::Mutex;
use std::time::Duration;

struct ServerIo {
    socket: UdpSocket,
    peer: Mutex<Option<SocketAddr>>,
}

impl DtlsIo for ServerIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        let peer = self.peer.lock().unwrap().expect("peer known");
        self.socket.send_to(packet, peer)?;
        Ok(())
    }
    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        self.socket.set_read_timeout(Some(timeout))?;
        let mut buf = vec![0u8; 65536];
        match self.socket.recv_from(&mut buf) {
            Ok((n, addr)) => {
                *self.peer.lock().unwrap() = Some(addr);
                buf.truncate(n);
                Ok(Some(buf))
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }
}

fn config() -> DtlsConfig {
    DtlsConfig {
        certificate: Certificate::generate_self_signed("dc-webrtc"),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: false,
        session_ticket_key: None,
        connection_id: None,
        pair_hint: None,
    }
}

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let port: u16 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
    match mode {
        "server" => {
            let socket = UdpSocket::bind(("127.0.0.1", port))?;
            // Report the bound port (the arg may be 0).
            eprintln!("LISTENING {}", socket.local_addr()?.port());
            let dtls = Dtls::accept(ServerIo { socket, peer: Mutex::new(None) }, &config())?;
            eprintln!("HANDSHAKE_OK");
            let endpoint = DcEndpoint::spawn(dtls, Role::Server, 5000);
            let mut channels = std::collections::HashMap::new();
            loop {
                match endpoint.recv_event_timeout(Duration::from_secs(120)) {
                    Some(EndpointEvent::ChannelOpened { channel }) => {
                        eprintln!("CHANNEL_OPEN stream={} label={}", channel.stream, channel.label);
                        channels.insert(channel.stream, channel);
                    }
                    Some(EndpointEvent::Message { stream, data, .. }) => {
                        if let Some(channel) = channels.get(&stream) {
                            let mut reply = b"re:".to_vec();
                            reply.extend_from_slice(&data);
                            channel.send_binary(&reply)?;
                        }
                    }
                    Some(_) => {}
                    None => return Ok(()),
                }
            }
        }
        "client" => {
            let socket = UdpSocket::bind("127.0.0.1:0")?;
            let peer: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
            let dtls = Dtls::connect(
                dc_webrtc::dtls::UdpDtlsIo { socket, peer },
                &config(),
            )?;
            eprintln!("HANDSHAKE_OK");
            let endpoint = DcEndpoint::spawn(dtls, Role::Client, 5000);
            let channel = endpoint.open_channel(ChannelParams {
                label: "echo".into(),
                ..Default::default()
            })?;
            let stdin = io::stdin();
            for line in stdin.lock().lines() {
                let line = line?;
                if line.is_empty() {
                    continue;
                }
                channel.send_binary(line.as_bytes())?;
                match endpoint.recv_event_timeout(Duration::from_secs(10)) {
                    Some(EndpointEvent::Message { data, .. }) => {
                        println!("{}", String::from_utf8_lossy(&data));
                        io::stdout().flush()?;
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
            eprintln!("usage: dc_echo <server|client> <port>");
            std::process::exit(2);
        }
    }
}
