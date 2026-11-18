//! Sans-io handshake (DtlsHandshake): two machines pumped
//! by hand on a virtual clock — full handshake, dropped
//! flight retransmission via tick, ticket resumption, and
//! connection-id records.

use dc_webrtc::dtls::{DtlsConfig, DtlsHandshake, DtlsSession};
use dc_webrtc::x509::Certificate;

const TICKET_KEY: [u8; 32] = [7u8; 32];

fn config(server: bool, resumption: bool, cid: Option<Vec<u8>>) -> DtlsConfig {
    DtlsConfig {
        certificate: Certificate::generate_self_signed(if server { "server" } else { "client" }),
        expected_peer_fingerprint: None,
        require_peer_certificate: false,
        session_resumption: resumption,
        session_ticket_key: if server && resumption {
            Some(TICKET_KEY)
        } else {
            None
        },
        connection_id: cid,
        pair_hint: None,
    }
}

/// Pump two machines to establishment on a virtual clock.
/// If drop_first_server_flight, the server's first flight
/// is discarded once, forcing a tick-driven retransmit.
fn pump(
    client_cfg: &DtlsConfig,
    server_cfg: &DtlsConfig,
    resume: Option<&DtlsSession>,
    drop_first_server_flight: bool,
) -> (dc_webrtc::dtls::DtlsCore, dc_webrtc::dtls::DtlsCore, bool) {
    let mut now = 0u64;
    let (mut client, flight) =
        DtlsHandshake::new_client(client_cfg, resume, now).expect("client start");
    let mut server = DtlsHandshake::new_server(server_cfg, now);
    let mut c2s = flight;
    let mut s2c: Vec<Vec<u8>> = Vec::new();
    let mut dropped = false;
    let mut saw_retransmit = false;
    for _ in 0..100_000 {
        if client.established() && server.established() {
            break;
        }
        for p in std::mem::take(&mut c2s) {
            s2c.extend(server.handle_datagram(&p, now));
        }
        if drop_first_server_flight && !dropped && !s2c.is_empty() {
            s2c.clear();
            dropped = true;
        }
        for p in std::mem::take(&mut s2c) {
            c2s.extend(client.handle_datagram(&p, now));
        }
        if client.established() && server.established() {
            break;
        }
        if client.failure().is_some() || server.failure().is_some() {
            break;
        }
        if c2s.is_empty() && s2c.is_empty() {
            let wait = [
                client.next_timeout(now),
                server.next_timeout(now),
            ]
            .into_iter()
            .flatten()
            .min()
            .unwrap_or(1000)
            .max(1);
            now += wait;
            let c_out = client.tick(now);
            if !c_out.is_empty() && dropped {
                saw_retransmit = true;
            }
            c2s.extend(c_out);
            s2c.extend(server.tick(now));
        }
    }
    assert!(
        client.failure().is_none() && server.failure().is_none(),
        "client failure={:?} server failure={:?}",
        client.failure(),
        server.failure()
    );
    assert!(
        client.established() && server.established(),
        "handshake did not establish (client={}, server={})",
        client.established(),
        server.established()
    );
    (
        client.into_core().expect("client core"),
        server.into_core().expect("server core"),
        saw_retransmit,
    )
}

fn echo(client: &mut dc_webrtc::dtls::DtlsCore, server: &mut dc_webrtc::dtls::DtlsCore) {
    let packet = client.encrypt_app(b"ping").expect("encrypt");
    let got = server
        .handle_datagram(&packet)
        .expect("handle")
        .expect("app data");
    assert_eq!(got, b"ping");
    let reply = server.encrypt_app(b"pong").expect("encrypt reply");
    let got = client
        .handle_datagram(&reply)
        .expect("handle reply")
        .expect("app data");
    assert_eq!(got, b"pong");
}

#[test]
fn sans_io_full_handshake_and_app_data() {
    let (mut client, mut server, _) = pump(&config(false, false, None), &config(true, false, None), None, false);
    echo(&mut client, &mut server);
}

#[test]
fn sans_io_dropped_flight_retransmits_via_tick() {
    let (mut client, mut server, retransmitted) =
        pump(&config(false, false, None), &config(true, false, None), None, true);
    assert!(retransmitted, "client retransmitted its flight after tick");
    echo(&mut client, &mut server);
}

#[test]
fn sans_io_ticket_resumption() {
    // First connection issues a ticket.
    let (mut client, _server, _) = pump(&config(false, true, None), &config(true, true, None), None, false);
    let session = client.take_session().expect("ticket captured");
    // Second connection resumes against a fresh server.
    let (mut client2, mut server2, _) =
        pump(&config(false, true, None), &config(true, true, None), Some(&session), false);
    assert!(client2.was_resumed(), "second handshake resumed");
    echo(&mut client2, &mut server2);
}

#[test]
fn sans_io_connection_id_handshake() {
    let cid = Some(vec![0xAA, 0xBB, 0xCC]);
    let (mut client, mut server, _) = pump(
        &config(false, false, cid.clone()),
        &config(true, false, cid),
        None,
        false,
    );
    echo(&mut client, &mut server);
}
