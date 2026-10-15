//! Minimal mDNS (RFC 6762) A-record resolution: browsers hide host
//! IPs behind "<uuid>.local" ICE candidates, and a native peer must
//! resolve them to reach the browser. One multicast query to
//! 224.0.0.251:5353; responders reply unicast to our ephemeral port.
//! std-only, mirroring webrtc/js/mdns.js.

use std::net::{Ipv4Addr, UdpSocket};
use std::time::Duration;

fn encode_name(name: &str) -> Vec<u8> {
    let mut out = Vec::new();
    for label in name.trim_end_matches('.').split('.') {
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out
}

fn build_query(id: u16, name: &str) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0, 0, 0]); // QDCOUNT=1
    out.extend_from_slice(&encode_name(name));
    out.extend_from_slice(&[0, 1, 0, 1]); // A, IN
    out
}

fn read_name(buf: &[u8], offset: usize) -> Option<(String, usize)> {
    let mut labels: Vec<String> = Vec::new();
    let mut pos = offset;
    let mut jumped_to: Option<usize> = None;
    for _ in 0..32 {
        let len = *buf.get(pos)?;
        if len == 0 {
            return Some((labels.join("."), jumped_to.unwrap_or(pos + 1)));
        }
        if len & 0xc0 == 0xc0 {
            let target = (((len & 0x3f) as usize) << 8) | (*buf.get(pos + 1)? as usize);
            if jumped_to.is_none() {
                jumped_to = Some(pos + 2);
            }
            pos = target;
            continue;
        }
        let start = pos + 1;
        let end = start + len as usize;
        labels.push(String::from_utf8_lossy(buf.get(start..end)?).into_owned());
        pos = end;
    }
    None
}

/// Extract the A record for `name` from a DNS response packet.
pub fn parse_a_record(packet: &[u8], name: &str) -> Option<Ipv4Addr> {
    if packet.len() < 12 {
        return None;
    }
    let qd = u16::from_be_bytes(packet[4..6].try_into().ok()?) as usize;
    let an = u16::from_be_bytes(packet[6..8].try_into().ok()?) as usize;
    let mut pos = 12;
    for _ in 0..qd {
        let (_, next) = read_name(packet, pos)?;
        pos = next + 4;
    }
    let wanted = name.trim_end_matches('.').to_lowercase();
    for _ in 0..an {
        let (rname, next) = read_name(packet, pos)?;
        pos = next;
        if pos + 10 > packet.len() {
            return None;
        }
        let rtype = u16::from_be_bytes(packet[pos..pos + 2].try_into().ok()?);
        let rdlen = u16::from_be_bytes(packet[pos + 8..pos + 10].try_into().ok()?) as usize;
        let rdata = packet.get(pos + 10..pos + 10 + rdlen)?;
        if rtype == 1 && rdlen == 4 && rname.to_lowercase() == wanted {
            return Some(Ipv4Addr::new(rdata[0], rdata[1], rdata[2], rdata[3]));
        }
        pos += 10 + rdlen;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name_wire(name: &str) -> Vec<u8> {
        let mut out = Vec::new();
        for label in name.split('.') {
            out.push(label.len() as u8);
            out.extend_from_slice(label.as_bytes());
        }
        out.push(0);
        out
    }

    #[test]
    fn parses_a_record_with_compression_pointer() {
        let mut packet = Vec::new();
        packet.extend_from_slice(&[0, 0, 0x84, 0x00, 0, 1, 0, 1, 0, 0, 0, 0]);
        packet.extend_from_slice(&name_wire("abc-123.local"));
        packet.extend_from_slice(&[0, 1, 0, 1]);
        packet.extend_from_slice(&[0xc0, 0x0c]); // name pointer to the question
        packet.extend_from_slice(&[0, 1, 0, 1]); // A, IN
        packet.extend_from_slice(&120u32.to_be_bytes());
        packet.extend_from_slice(&[0, 4, 192, 168, 1, 20]);
        assert_eq!(
            parse_a_record(&packet, "abc-123.local"),
            Some(Ipv4Addr::new(192, 168, 1, 20))
        );
        assert_eq!(parse_a_record(&packet, "other.local"), None);
        assert_eq!(parse_a_record(&[1, 2, 3], "abc-123.local"), None);
    }
}

/// Resolve a ".local" hostname to an IPv4 address (1.5 s budget).
pub fn resolve_ipv4(name: &str) -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.set_read_timeout(Some(Duration::from_millis(1500))).ok()?;
    let query = build_query(0x4d44, name);
    socket.send_to(&query, "224.0.0.251:5353").ok()?;
    let mut buf = [0u8; 4096];
    let deadline = std::time::Instant::now() + Duration::from_millis(1500);
    let mut resent = false;
    loop {
        match socket.recv_from(&mut buf) {
            Ok((n, _)) => {
                if let Some(ip) = parse_a_record(&buf[..n], name) {
                    return Some(ip);
                }
                if std::time::Instant::now() > deadline {
                    return None;
                }
            }
            Err(_) => {
                if !resent {
                    resent = true;
                    let _ = socket.send_to(&query, "224.0.0.251:5353");
                    continue;
                }
                return None;
            }
        }
    }
}
