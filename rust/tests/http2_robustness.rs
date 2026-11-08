//! HTTP/2 + HPACK robustness corpus for the homegrown stack
//! (grpc_dc::http2): hostile inputs must error or be ignored,
//! never panic, hang, or overrun flow-control windows; well-
//! formed edge cases (CONTINUATION chains, padding, priority
//! fields) must decode exactly. Connection-level cases run
//! accept_h2 over an in-memory duplex against a raw frame
//! writer, so no sockets are involved.

use futures_util::StreamExt;
use grpc_dc::http2::{
    accept_h2, frame_type_h2, H2Event, H2ServerConn, H2Stream, HpackDecoder, HpackEncoder,
    H2_PREFACE,
};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

// ---------------------------------------------------------------------------
// HPACK decoder corpus
// ---------------------------------------------------------------------------

fn decode(block: &[u8]) -> Result<Vec<(String, String)>, grpc_dc::Status> {
    HpackDecoder::default().decode(block)
}

#[test]
fn hpack_index_zero_and_out_of_range_are_errors() {
    assert!(decode(&[0x80]).is_err(), "index 0 is reserved");
    assert!(decode(&[0xff, 0x01]).is_err(), "index 128 names nothing");
}

#[test]
fn hpack_truncated_inputs_are_errors() {
    assert!(decode(&[0xff]).is_err(), "truncated prefixed int");
    // Literal, incremental indexing; name string promises 5
    // bytes and delivers 2.
    assert!(decode(&[0x40, 0x05, b'a', b'b']).is_err(), "truncated string");
    // Huffman-coded name string longer than the block.
    assert!(decode(&[0x40, 0x84, 0xff]).is_err(), "truncated huffman string");
}

#[test]
fn hpack_malformed_huffman_is_error() {
    // A name string consisting of the EOS symbol (30 one-bits)
    // must be rejected, not decoded as data.
    assert!(decode(&[0x40, 0x84, 0xff, 0xff, 0xff, 0xff]).is_err(), "EOS in string");
    // Non-EOS padding: 0x00 decodes a symbol but leaves zero
    // padding bits instead of a prefix of EOS.
    let bad_pad = decode(&[0x40, 0x81, 0x00]);
    assert!(bad_pad.is_err(), "bad huffman padding must error: {bad_pad:?}");
}

#[test]
fn hpack_oversized_int_is_error() {
    // Literal without indexing, then an integer with a dozen
    // continuation bytes: the decoder must stop, not overflow.
    let mut block = vec![0x0f];
    block.extend_from_slice(&[0xff; 12]);
    block.push(0x01);
    assert!(decode(&block).is_err(), "oversized prefixed int");
}

#[test]
fn hpack_dynamic_table_roundtrip_and_eviction() {
    let mut dec = HpackDecoder::default();
    // Incremental indexing: name = static 5 (":path"), value "/x".
    let headers = dec.decode(&[0x45, 0x02, b'/', b'x']).unwrap();
    assert_eq!(headers, vec![(":path".to_string(), "/x".to_string())]);
    // First dynamic entry is index 62.
    let headers = dec.decode(&[0xbe]).unwrap();
    assert_eq!(headers, vec![(":path".to_string(), "/x".to_string())]);
    // Dynamic table size update to 0 evicts; index 62 then fails.
    assert!(dec.decode(&[0x20]).unwrap().is_empty());
    assert!(dec.decode(&[0xbe]).is_err(), "evicted dynamic index");
}

#[test]
fn hpack_encoder_decoder_roundtrip() {
    let headers = vec![
        (":method".to_string(), "POST".to_string()),
        (":path".to_string(), "/echo.Echo/Unary".to_string()),
        ("content-type".to_string(), "application/grpc".to_string()),
        ("x-custom".to_string(), "some value".to_string()),
    ];
    let block = HpackEncoder::encode(&headers);
    let decoded = decode(&block).unwrap();
    assert_eq!(decoded, headers);
}

// ---------------------------------------------------------------------------
// Raw connection corpus (accept_h2 over a duplex)
// ---------------------------------------------------------------------------

const SETTINGS: u8 = frame_type_h2::SETTINGS as u8;
const HEADERS: u8 = frame_type_h2::HEADERS as u8;
const CONTINUATION: u8 = frame_type_h2::CONTINUATION as u8;
const DATA: u8 = frame_type_h2::DATA as u8;
const WINDOW_UPDATE: u8 = frame_type_h2::WINDOW_UPDATE as u8;

fn frame(ty: u8, flags: u8, stream_id: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(9 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes()[1..]);
    out.push(ty);
    out.push(flags);
    out.extend_from_slice(&stream_id.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn request_block(path: &str) -> Vec<u8> {
    HpackEncoder::encode(&vec![
        (":method".into(), "POST".into()),
        (":path".into(), path.into()),
        (":scheme".into(), "http".into()),
        ("content-type".into(), "application/grpc".into()),
    ])
}

struct Client {
    side: DuplexStream,
}

impl Client {
    // Preface + empty SETTINGS, then consume the server's
    // SETTINGS and connection WINDOW_UPDATE so subsequent
    // reads are aligned to frames the test cares about.
    async fn handshake(&mut self) {
        self.side.write_all(H2_PREFACE).await.unwrap();
        self.side.write_all(&frame(SETTINGS, 0, 0, &[])).await.unwrap();
        self.side.flush().await.unwrap();
        let _ = self.read_frame().await;
        let _ = self.read_frame().await;
    }

    async fn write(&mut self, bytes: &[u8]) {
        self.side.write_all(bytes).await.unwrap();
        self.side.flush().await.unwrap();
    }

    async fn read_frame(&mut self) -> (u8, u8, u32, Vec<u8>) {
        let mut head = [0u8; 9];
        self.side.read_exact(&mut head).await.unwrap();
        let len = ((head[0] as usize) << 16) | ((head[1] as usize) << 8) | head[2] as usize;
        let mut payload = vec![0u8; len];
        self.side.read_exact(&mut payload).await.unwrap();
        (
            head[3],
            head[4],
            u32::from_be_bytes([head[5], head[6], head[7], head[8]]) & 0x7fff_ffff,
            payload,
        )
    }

    // Sum DATA payload bytes until `want` arrive, the deadline
    // passes, or a non-DATA frame shows up.
    async fn collect_data(&mut self, want: usize, deadline: Duration) -> usize {
        let mut got = 0usize;
        let end = tokio::time::Instant::now() + deadline;
        while got < want {
            let Some(remaining) = end.checked_duration_since(tokio::time::Instant::now()) else {
                break;
            };
            match tokio::time::timeout(remaining, self.read_frame()).await {
                Ok((DATA, _, _, payload)) => got += payload.len(),
                Ok(_) => {}
                Err(_) => break,
            }
        }
        got
    }
}

async fn pair() -> (Client, H2ServerConn) {
    let (client_side, server_side) = tokio::io::duplex(1024 * 1024);
    let mut client = Client { side: client_side };
    let server_join = tokio::spawn(accept_h2(server_side));
    client.handshake().await;
    let server = server_join.await.unwrap().unwrap();
    (client, server)
}

async fn next_stream(server: &mut H2ServerConn) -> H2Stream {
    tokio::time::timeout(Duration::from_secs(5), server.incoming.next())
        .await
        .expect("stream within timeout")
        .expect("incoming stream")
}

async fn expect_headers(stream: &H2Stream) -> Vec<(String, String)> {
    match tokio::time::timeout(Duration::from_secs(5), stream.next_event())
        .await
        .expect("headers within timeout")
    {
        Some(H2Event::Headers { headers, .. }) => headers,
        other => panic!("expected Headers, got {other:?}"),
    }
}

fn path_of(headers: &[(String, String)]) -> String {
    headers
        .iter()
        .find(|(k, _)| k == ":path")
        .map(|(_, v)| v.clone())
        .unwrap_or_default()
}

#[tokio::test]
async fn continuation_chain_reassembles_one_header_block() {
    let (mut client, mut server) = pair().await;
    let block = request_block("/echo.Echo/Unary");
    let third = block.len() / 3;
    // HEADERS without END_HEADERS, then two CONTINUATION frames;
    // the split points land mid-string on purpose.
    client.write(&frame(HEADERS, 0x1, 1, &block[..third])).await;
    client.write(&frame(CONTINUATION, 0x0, 1, &block[third..2 * third])).await;
    client.write(&frame(CONTINUATION, 0x4, 1, &block[2 * third..])).await;
    let stream = next_stream(&mut server).await;
    let headers = expect_headers(&stream).await;
    assert_eq!(path_of(&headers), "/echo.Echo/Unary");
}

#[tokio::test]
async fn padded_and_priority_headers_and_padded_data_decode() {
    let (mut client, mut server) = pair().await;
    let block = request_block("/echo.Echo/Unary");
    // HEADERS with PADDED | PRIORITY | END_HEADERS: pad-length
    // byte, 5 priority bytes, block, 4 padding bytes.
    let mut payload = vec![4u8];
    payload.extend_from_slice(&[0, 0, 0, 1, 16]);
    payload.extend_from_slice(&block);
    payload.extend_from_slice(&[0, 0, 0, 0]);
    client.write(&frame(HEADERS, 0x8 | 0x20 | 0x4, 1, &payload)).await;
    let stream = next_stream(&mut server).await;
    assert_eq!(path_of(&expect_headers(&stream).await), "/echo.Echo/Unary");

    // PADDED DATA: pad-length byte, real payload, 3 pad bytes.
    let mut data = vec![3u8];
    data.extend_from_slice(b"hello");
    data.extend_from_slice(&[0, 0, 0]);
    client.write(&frame(DATA, 0x8 | 0x1, 1, &data)).await;
    match tokio::time::timeout(Duration::from_secs(5), stream.next_event())
        .await
        .expect("data within timeout")
    {
        Some(H2Event::Data { data, end_stream }) => {
            assert_eq!(data.as_ref(), b"hello");
            assert!(end_stream);
        }
        other => panic!("expected Data, got {other:?}"),
    }
}

#[tokio::test]
async fn malformed_hpack_block_drops_stream_but_connection_survives() {
    let (mut client, mut server) = pair().await;
    // 0xff starts an indexed field whose integer never ends.
    client.write(&frame(HEADERS, 0x4 | 0x1, 1, &[0xff])).await;
    let nothing = tokio::time::timeout(Duration::from_millis(300), server.incoming.next()).await;
    assert!(!matches!(nothing, Ok(Some(_))), "malformed block must not deliver a stream");
    // The connection must still serve the next stream.
    client
        .write(&frame(HEADERS, 0x4 | 0x1, 3, &request_block("/echo.Echo/Unary")))
        .await;
    let stream = next_stream(&mut server).await;
    assert_eq!(path_of(&expect_headers(&stream).await), "/echo.Echo/Unary");
}

#[tokio::test]
async fn unknown_frames_and_partial_frames_do_not_wedge() {
    let (mut client, mut server) = pair().await;
    // Unknown frame type with a small payload: ignored.
    client.write(&frame(0xff, 0, 0, &[1, 2, 3])).await;
    // A HEADERS frame header promising 100 payload bytes, of
    // which only 5 arrive: nothing may be delivered from it.
    let mut partial = frame(HEADERS, 0x4, 1, &request_block("/x"));
    partial.truncate(9 + 5);
    // Fix the declared length back up to 100 for the promise.
    partial[0] = 0;
    partial[1] = 0;
    partial[2] = 100;
    client.write(&partial).await;
    let nothing = tokio::time::timeout(Duration::from_millis(300), server.incoming.next()).await;
    assert!(!matches!(nothing, Ok(Some(_))), "partial frame must not deliver a stream");
}

async fn expect_goaway(client: &mut Client) {
    // Skip any SETTINGS ack / WINDOW_UPDATE frames still in
    // flight from the handshake; the GOAWAY must follow.
    let payload = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let (ty, _, id, payload) = client.read_frame().await;
            if ty == frame_type_h2::GOAWAY as u8 {
                assert_eq!(id, 0);
                break payload;
            }
        }
    })
    .await
    .expect("GOAWAY within timeout");
    assert_eq!(payload.len(), 8);
    assert_eq!(
        u32::from_be_bytes(payload[4..8].try_into().unwrap()),
        grpc_dc::http2::error_h2::PROTOCOL_ERROR,
        "GOAWAY must carry PROTOCOL_ERROR"
    );
}

#[tokio::test]
async fn interleaved_frame_during_header_block_is_connection_error() {
    let (mut client, mut server) = pair().await;
    let block = request_block("/echo.Echo/Unary");
    // HEADERS without END_HEADERS opens a block; a PING in the
    // middle of it is a connection error (RFC 7540 4.3).
    client.write(&frame(HEADERS, 0x0, 1, &block[..4])).await;
    client.write(&frame(frame_type_h2::PING as u8, 0, 0, &[1, 2, 3, 4, 5, 6, 7, 8])).await;
    expect_goaway(&mut client).await;
    // Either the incoming channel closes with the connection
    // or it stays open but silent; it must never yield a stream.
    let nothing = tokio::time::timeout(Duration::from_millis(300), server.incoming.next()).await;
    assert!(!matches!(nothing, Ok(Some(_))), "no stream from a broken block");
}

#[tokio::test]
async fn stray_continuation_is_connection_error() {
    let (mut client, mut server) = pair().await;
    // CONTINUATION with no open header block (RFC 7540 6.10).
    client.write(&frame(CONTINUATION, 0x4, 1, &request_block("/x"))).await;
    expect_goaway(&mut client).await;
    let nothing = tokio::time::timeout(Duration::from_millis(300), server.incoming.next()).await;
    assert!(!matches!(nothing, Ok(Some(_))), "stray CONTINUATION must not deliver a stream");
}

#[tokio::test]
async fn send_data_respects_peer_flow_control_window() {
    let (mut client, mut server) = pair().await;
    // Shrink the server's send window: INITIAL_WINDOW_SIZE
    // 16384 in a client SETTINGS frame before the stream opens.
    let mut settings = Vec::new();
    settings.extend_from_slice(&4u16.to_be_bytes());
    settings.extend_from_slice(&16384u32.to_be_bytes());
    client.write(&frame(SETTINGS, 0, 0, &settings)).await;
    client
        .write(&frame(HEADERS, 0x4 | 0x1, 1, &request_block("/echo.Echo/Unary")))
        .await;
    let stream = next_stream(&mut server).await;
    let _ = expect_headers(&stream).await;

    let payload = vec![b'x'; 40_000];
    let sender = {
        let stream = stream.clone();
        tokio::spawn(async move { stream.send_data(payload.into(), false).await })
    };
    // Exactly one window (16384) may arrive before any
    // WINDOW_UPDATE; flow-control abuse must not overrun it.
    let first = client.collect_data(40_000, Duration::from_millis(700)).await;
    assert_eq!(first, 16_384, "sender must stop at the peer window");
    // Open stream + connection windows by another window.
    for id in [1u32, 0] {
        client
            .write(&frame(WINDOW_UPDATE, 0, id, &16384u32.to_be_bytes()))
            .await;
    }
    let second = client.collect_data(40_000 - 16_384, Duration::from_secs(5)).await;
    assert_eq!(second, 16_384, "one more window flows after WINDOW_UPDATE");
    // Final top-up releases the tail.
    for id in [1u32, 0] {
        client
            .write(&frame(WINDOW_UPDATE, 0, id, &16384u32.to_be_bytes()))
            .await;
    }
    let third = client.collect_data(40_000 - 32_768, Duration::from_secs(5)).await;
    assert_eq!(third, 7_232, "tail flows after the final WINDOW_UPDATE");
    sender.await.unwrap().unwrap();
}
