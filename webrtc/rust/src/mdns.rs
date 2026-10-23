//! Minimal mDNS (RFC 6762) A/AAAA resolution: browsers hide host
//! IPs behind "<uuid>.local" ICE candidates, and a native peer must
//! resolve them to reach the browser. One multicast query to
//! 224.0.0.251:5353; replies may come unicast or multicast.
//! std-only, mirroring webrtc/js/mdns.js.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, UdpSocket};
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
    out.extend_from_slice(&[0, 0, 0, 2, 0, 0, 0, 0, 0, 0]); // QDCOUNT=2: A and AAAA
    // IN|QU: the QU bit (RFC 6762 section 5.4) asks for a
    // unicast response to our ephemeral port; without it some
    // responders answer by multicast to :5353 only (we listen
    // there too; see resolve_ip).
    let wire = encode_name(name);
    out.extend_from_slice(&wire);
    out.extend_from_slice(&[0, 1, 0x80, 1]); // A
    out.extend_from_slice(&wire);
    out.extend_from_slice(&[0, 28, 0x80, 1]); // AAAA
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

fn find_record<'a>(packet: &'a [u8], name: &str, want_type: u16, want_len: usize) -> Option<&'a [u8]> {
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
        if rtype == want_type && rdlen == want_len && rname.to_lowercase() == wanted {
            return Some(rdata);
        }
        pos += 10 + rdlen;
    }
    None
}

/// Extract the A record for `name` from a DNS response packet.
pub fn parse_a_record(packet: &[u8], name: &str) -> Option<Ipv4Addr> {
    let rdata = find_record(packet, name, 1, 4)?;
    Some(Ipv4Addr::new(rdata[0], rdata[1], rdata[2], rdata[3]))
}

/// Extract the AAAA record for `name` from a DNS response packet.
pub fn parse_aaaa_record(packet: &[u8], name: &str) -> Option<Ipv6Addr> {
    let rdata = find_record(packet, name, 28, 16)?;
    let octets: [u8; 16] = rdata.try_into().ok()?;
    Some(Ipv6Addr::from(octets))
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

    #[test]
    fn parses_aaaa_record_with_compression_pointer() {
        let mut packet = Vec::new();
        packet.extend_from_slice(&[0, 0, 0x84, 0x00, 0, 1, 0, 1, 0, 0, 0, 0]);
        packet.extend_from_slice(&name_wire("abc-123.local"));
        packet.extend_from_slice(&[0, 28, 0, 1]);
        packet.extend_from_slice(&[0xc0, 0x0c]); // name pointer to the question
        packet.extend_from_slice(&[0, 28, 0, 1]); // AAAA, IN
        packet.extend_from_slice(&120u32.to_be_bytes());
        let addr = Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 0x1234);
        packet.extend_from_slice(&16u16.to_be_bytes());
        packet.extend_from_slice(&addr.octets());
        assert_eq!(parse_aaaa_record(&packet, "abc-123.local"), Some(addr));
        assert_eq!(parse_aaaa_record(&packet, "other.local"), None);
        assert_eq!(parse_a_record(&packet, "abc-123.local"), None);
    }

    #[test]
    fn query_asks_both_families_with_qu_bit() {
        let query = build_query(0, "abc-123.local");
        assert_eq!(u16::from_be_bytes(query[4..6].try_into().unwrap()), 2);
        let name_len = name_wire("abc-123.local").len();
        let first = 12 + name_len;
        assert_eq!(&query[first..first + 4], &[0, 1, 0x80, 1]);
        let second = first + 4 + name_len;
        assert_eq!(&query[second..second + 4], &[0, 28, 0x80, 1]);
    }
}

/// Resolve a ".local" hostname to an IP address (1.5 s budget).
/// Responders may answer unicast to the query socket (the query
/// asks with the QU bit) or multicast to the group address —
/// Chromium does the latter — so listen on both: the ephemeral
/// query socket and a group membership on :5353 (best effort;
/// the port may be taken).
pub fn resolve_ip(name: &str) -> Option<IpAddr> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    let group = UdpSocket::bind("0.0.0.0:5353").ok().and_then(|socket| {
        socket
            .join_multicast_v4(&Ipv4Addr::new(224, 0, 0, 251), &Ipv4Addr::UNSPECIFIED)
            .ok()?;
        Some(socket)
    });
    let query = build_query(0, name);
    socket.send_to(&query, "224.0.0.251:5353").ok()?;
    let deadline = std::time::Instant::now() + Duration::from_millis(1500);
    let resend_at = std::time::Instant::now() + Duration::from_millis(750);
    let mut resent = false;
    let mut buf = [0u8; 4096];
    loop {
        if !resent && std::time::Instant::now() >= resend_at {
            resent = true;
            let _ = socket.send_to(&query, "224.0.0.251:5353");
        }
        if std::time::Instant::now() > deadline {
            return None;
        }
        for candidate in [Some(&socket), group.as_ref()].into_iter().flatten() {
            candidate
                .set_read_timeout(Some(Duration::from_millis(50)))
                .ok()?;
            if let Ok((n, _)) = candidate.recv_from(&mut buf) {
                if let Some(ip) = parse_a_record(&buf[..n], name) {
                    return Some(IpAddr::V4(ip));
                }
                if let Some(ip) = parse_aaaa_record(&buf[..n], name) {
                    return Some(IpAddr::V6(ip));
                }
            }
        }
    }
}
