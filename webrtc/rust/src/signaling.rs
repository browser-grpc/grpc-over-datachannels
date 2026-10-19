//! Headless signaling over byte streams (serial / BLE / UART).
//!
//! WebRTC needs an out-of-band channel for SDP and ICE
//! candidates; browsers use WebSocket/HTTP, but a headless
//! embedded peer has neither. This module frames signaling
//! messages over any `Read`/`Write` byte stream — a UART, a BLE
//! GATT characteristic bridged to a stream, a pipe — with no
//! server and no IP stack involved:
//!
//! `[u32 BE length][u8 kind][payload]`, length covering kind +
//! payload. Kinds: 1 = Offer (SDP), 2 = Answer (SDP),
//! 3 = Candidate (one SDP candidate line), 4 = EndOfCandidates.
//!
//! `examples/peer_serial.rs` runs two peers this way over stdio
//! pipes; the same framing drops onto a serial device unchanged.

use std::io::{self, Read, Write};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SignalMessage {
    Offer(String),
    Answer(String),
    Candidate(String),
    EndOfCandidates,
}

const KIND_OFFER: u8 = 1;
const KIND_ANSWER: u8 = 2;
const KIND_CANDIDATE: u8 = 3;
const KIND_END: u8 = 4;
const MAX_SIGNAL_BYTES: usize = 1 << 20;

fn kind_of(msg: &SignalMessage) -> u8 {
    match msg {
        SignalMessage::Offer(_) => KIND_OFFER,
        SignalMessage::Answer(_) => KIND_ANSWER,
        SignalMessage::Candidate(_) => KIND_CANDIDATE,
        SignalMessage::EndOfCandidates => KIND_END,
    }
}

fn payload_of(msg: &SignalMessage) -> &[u8] {
    match msg {
        SignalMessage::Offer(s) | SignalMessage::Answer(s) | SignalMessage::Candidate(s) => {
            s.as_bytes()
        }
        SignalMessage::EndOfCandidates => &[],
    }
}

/// Write one framed signaling message and flush.
pub fn write_signal<W: Write>(w: &mut W, msg: &SignalMessage) -> io::Result<()> {
    let payload = payload_of(msg);
    let len = (payload.len() + 1) as u32;
    w.write_all(&len.to_be_bytes())?;
    w.write_all(&[kind_of(msg)])?;
    w.write_all(payload)?;
    w.flush()
}

/// Read one framed signaling message. `Ok(None)` on a clean EOF
/// at a frame boundary (peer closed the stream); an EOF
/// mid-frame is an error.
pub fn read_signal<R: Read>(r: &mut R) -> io::Result<Option<SignalMessage>> {
    let mut len_buf = [0u8; 4];
    match read_exact_or_eof(r, &mut len_buf)? {
        false => return Ok(None),
        true => {}
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > MAX_SIGNAL_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "signaling frame length out of range",
        ));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    let (kind, payload) = body.split_at(1);
    let text = |bytes: &[u8]| -> io::Result<String> {
        String::from_utf8(bytes.to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "signaling not UTF-8"))
    };
    let msg = match kind[0] {
        KIND_OFFER => SignalMessage::Offer(text(payload)?),
        KIND_ANSWER => SignalMessage::Answer(text(payload)?),
        KIND_CANDIDATE => SignalMessage::Candidate(text(payload)?),
        KIND_END => SignalMessage::EndOfCandidates,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unknown signaling kind",
            ))
        }
    };
    Ok(Some(msg))
}

/// read_exact that reports a clean EOF before the first byte.
fn read_exact_or_eof<R: Read>(r: &mut R, buf: &mut [u8]) -> io::Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        match r.read(&mut buf[filled..]) {
            Ok(0) => {
                if filled == 0 {
                    return Ok(false);
                }
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "signaling stream closed mid-frame",
                ));
            }
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn signal_roundtrip_all_kinds() {
        let msgs = [
            SignalMessage::Offer("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n".into()),
            SignalMessage::Candidate("candidate:1 1 udp 2130706431 127.0.0.1 5000 typ host".into()),
            SignalMessage::EndOfCandidates,
            SignalMessage::Answer("v=0\r\n".into()),
        ];
        let mut stream = Vec::new();
        for m in &msgs {
            write_signal(&mut stream, m).unwrap();
        }
        let mut cursor = Cursor::new(stream);
        for m in &msgs {
            assert_eq!(read_signal(&mut cursor).unwrap().as_ref(), Some(m));
        }
        assert_eq!(read_signal(&mut cursor).unwrap(), None, "clean EOF");
    }

    #[test]
    fn signal_mid_frame_eof_is_error() {
        let mut stream = Vec::new();
        write_signal(&mut stream, &SignalMessage::Offer("x".repeat(100))).unwrap();
        stream.truncate(10);
        let mut cursor = Cursor::new(stream);
        assert!(read_signal(&mut cursor).is_err());
    }
}
