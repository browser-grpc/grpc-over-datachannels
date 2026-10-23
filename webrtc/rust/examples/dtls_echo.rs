//! DTLS echo harness: `dtls_echo server <port>` or `dtls_echo client <port>`.
//! Client sends each stdin line as app data and prints the reply; the
//! server echoes with an "echo:" prefix. Handshake outcomes and the peer
//! fingerprint go to stderr so tests can assert on them.

use dc_webrtc::dtls::{Dtls, DtlsConfig, DtlsIo};
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
        let peer = self.peer.lock().unwrap().expect("peer known after first packet");
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

struct ClientIo {
    socket: UdpSocket,
    peer: SocketAddr,
}

impl DtlsIo for ClientIo {
    fn send_packet(&mut self, packet: &[u8]) -> io::Result<()> {
        self.socket.send_to(packet, self.peer)?;
        Ok(())
    }
    fn recv_packet(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        self.socket.set_read_timeout(Some(timeout))?;
        let mut buf = vec![0u8; 65536];
        match self.socket.recv(&mut buf) {
            Ok(n) => {
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
    config_resume(false)
}

fn config_resume(session_resumption: bool) -> DtlsConfig {
    DtlsConfig {
        certificate: Certificate::generate_self_signed("dc-webrtc"),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption,
        // Servers need a sealing key to issue/honor RFC 5077
        // tickets. Fixed key: test harness only, never production.
        session_ticket_key: if session_resumption { Some([0x42; 32]) } else { None },
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
            // `server <port> resume`: issue RFC 5077 tickets and
            // keep accepting (idle timeout per connection) so a
            // client can resume against the same server process.
            let resume = args.get(3).map(|s| s.as_str()) == Some("resume");
            let socket = UdpSocket::bind(("127.0.0.1", port))?;
            // Report the bound port (the arg may be 0): callers
            // bind ephemeral and read the allocated port here
            // instead of probe-close-rebinding a guessed one.
            eprintln!("LISTENING {}", socket.local_addr()?.port());
            loop {
                let io = ServerIo { socket: socket.try_clone()?, peer: Mutex::new(None) };
                let mut conn = match Dtls::accept(io, &config_resume(resume)) {
                    Ok(conn) => conn,
                    Err(e) if resume => {
                        eprintln!("accept retry after: {e}");
                        continue;
                    }
                    Err(e) => return Err(e),
                };
                eprintln!(
                    "HANDSHAKE_OK peer_fp={} resumed={}",
                    conn.peer_fingerprint().unwrap_or_default(),
                    conn.was_resumed()
                );
                loop {
                    let data = if resume {
                        match conn.recv_app_timeout(Duration::from_secs(3)) {
                            Ok(Some(data)) => data,
                            _ => break, // idle or closed: accept the next connection
                        }
                    } else {
                        conn.recv_app()?
                    };
                    let mut reply = b"echo:".to_vec();
                    reply.extend_from_slice(&data);
                    conn.send_app(&reply)?;
                }
                if !resume {
                    return Ok(());
                }
                // Answer close_notify so the peer finishes its
                // shutdown (OpenSSL s_client only then writes
                // -sess_out and exits).
                conn.close();
            }
        }
        "client" => {
            let socket = UdpSocket::bind("127.0.0.1:0")?;
            let peer: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
            let io = ClientIo { socket, peer };
            let mut conn = Dtls::connect(io, &config())?;
            eprintln!("HANDSHAKE_OK peer_fp={}", conn.peer_fingerprint().unwrap_or_default());
            let stdin = io::stdin();
            for line in stdin.lock().lines() {
                let line = line?;
                if line.is_empty() {
                    continue;
                }
                conn.send_app(line.as_bytes())?;
                let reply = conn.recv_app()?;
                println!("{}", String::from_utf8_lossy(&reply));
                io::stdout().flush()?;
            }
            Ok(())
        }
        _ => {
            eprintln!("usage: dtls_echo <server|client> <port>");
            std::process::exit(2);
        }
    }
}
