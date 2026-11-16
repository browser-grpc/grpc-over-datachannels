//! Cross-checks of the hand-rolled EC stacks against the
//! system OpenSSL: signatures each side produces verify on
//! the other, and ECDH secrets agree. Skips when the openssl
//! CLI is not on PATH (Dockerfile.ci installs it).

use dc_webrtc::p256;
use dc_webrtc::p384;
use std::io::Write;
use std::process::{Command, Stdio};

fn openssl(args: &[&str], stdin_data: &[u8]) -> Option<Vec<u8>> {
    let mut child = Command::new("openssl")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    child.stdin.take().unwrap().write_all(stdin_data).ok()?;
    let out = child.wait_with_output().ok()?;
    if out.status.success() {
        Some(out.stdout)
    } else {
        None
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn p256_signatures_cross_verify_with_openssl() {
    if Command::new("openssl").arg("version").output().is_err() {
        eprintln!("skip: openssl CLI not available");
        return;
    }
    let digest = [7u8; 32];
    // Ours -> OpenSSL verify. PEM key from our uncompressed point.
    let (secret, public) = p256::PrivateKey::generate();
    let (r, s) = secret.sign(&digest);
    let mut der_sig = vec![0x30, 0, 0x02];
    let r_b = trim_int(&r);
    let s_b = trim_int(&s);
    der_sig[1] = (2 + r_b.len() + 2 + s_b.len()) as u8;
    der_sig.extend([r_b.len() as u8]);
    der_sig.extend(r_b);
    der_sig.extend([0x02, s_b.len() as u8]);
    der_sig.extend(s_b);
    // Build a SubjectPublicKeyInfo PEM via openssl pkeyutl is
    // fiddly; use `openssl pkey` with a raw EC key from DER SPKI.
    let spki = spki_p256(&public.encode_uncompressed());
    let pem = pem_wrap("PUBLIC KEY", &spki);
    let ok = openssl(
        &["pkeyutl", "-verify", "-pubin", "-inkey", "/dev/stdin", "-pkeyopt", "digest:SHA256", "-sigfile", "/dev/stdin"],
        &[],
    );
    let _ = ok; // replaced below by dgst, kept simple:
    let mut cmd = Command::new("openssl");
    cmd.args(["dgst", "-sha256", "-verify", "/dev/stdin", "-signature", "/dev/stdin"]);
    // dgst needs files; use temp files instead.
    let dir = std::env::temp_dir();
    let key_path = dir.join("dc-p256-pub.pem");
    let sig_path = dir.join("dc-p256-sig.der");
    let msg_path = dir.join("dc-p256-msg.bin");
    // We sign the digest directly in our API; OpenSSL dgst
    // hashes the file, so sign the file bytes' hash instead:
    // recompute with a real message.
    let msg = b"cross-check message";
    let msg_digest = dc_webrtc::crypto::sha256(msg);
    let (r2, s2) = secret.sign(&msg_digest);
    let mut der2 = vec![0x30, 0, 0x02];
    let rb = trim_int(&r2);
    let sb = trim_int(&s2);
    der2[1] = (2 + rb.len() + 2 + sb.len()) as u8;
    der2.extend([rb.len() as u8]);
    der2.extend(rb);
    der2.extend([0x02, sb.len() as u8]);
    der2.extend(sb);
    std::fs::write(&key_path, pem.as_bytes()).unwrap();
    std::fs::write(&sig_path, &der2).unwrap();
    std::fs::write(&msg_path, msg).unwrap();
    let out = Command::new("openssl")
        .args([
            "dgst", "-sha256", "-verify",
            key_path.to_str().unwrap(),
            "-signature", sig_path.to_str().unwrap(),
            msg_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("Verified OK"),
        "openssl rejected our P-256 signature: {} {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );

    // OpenSSL -> our verify.
    let sig_hex = openssl(
        &["dgst", "-sha256", "-sign", key_path.to_str().unwrap(), msg_path.to_str().unwrap()],
        &[],
    );
    // key_path is a public key; signing needs a private key.
    // Generate one with OpenSSL and export both PEMs.
    let priv_path = dir.join("dc-p256-priv.pem");
    let pub2_path = dir.join("dc-p256-pub2.pem");
    assert!(Command::new("openssl")
        .args(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", priv_path.to_str().unwrap()])
        .status()
        .unwrap()
        .success());
    assert!(Command::new("openssl")
        .args(["ec", "-in", priv_path.to_str().unwrap(), "-pubout", "-out", pub2_path.to_str().unwrap()])
        .status()
        .unwrap()
        .success());
    let sig = Command::new("openssl")
        .args(["dgst", "-sha256", "-sign", priv_path.to_str().unwrap(), msg_path.to_str().unwrap()])
        .output()
        .unwrap()
        .stdout;
    let _ = sig_hex;
    // Parse DER signature and the SPKI to recover (r, s) and the point.
    let (sr, ss) = parse_der_sig(&sig);
    let spki_bytes = pem_unwrap(&std::fs::read_to_string(pub2_path).unwrap());
    // SPKI ends with the 65-byte uncompressed point (bit string).
    let point = &spki_bytes[spki_bytes.len() - 65..];
    let mut point_arr = [0u8; 65];
    point_arr.copy_from_slice(point);
    let pub_key = p256::PublicKey::decode(&point_arr).expect("decode openssl point");
    let digest2 = dc_webrtc::crypto::sha256(msg);
    assert!(pub_key.verify(&digest2, &to32(&sr), &to32(&ss)), "our verifier rejected OpenSSL P-256 signature");
    assert_eq!(hex(&r).len(), 64);
}

#[test]
fn p384_key_agreement_with_openssl() {
    if Command::new("openssl").arg("version").output().is_err() {
        eprintln!("skip: openssl CLI not available");
        return;
    }
    // Our ECDH against an OpenSSL-generated P-384 key: derive
    // via openssl pkeyutl and compare with our ecdh output.
    let dir = std::env::temp_dir();
    let priv_path = dir.join("dc-p384-priv.pem");
    let pub_path = dir.join("dc-p384-pub.pem");
    assert!(Command::new("openssl")
        .args(["ecparam", "-name", "secp384r1", "-genkey", "-noout", "-out", priv_path.to_str().unwrap()])
        .status()
        .unwrap()
        .success());
    assert!(Command::new("openssl")
        .args(["ec", "-in", priv_path.to_str().unwrap(), "-pubout", "-out", pub_path.to_str().unwrap()])
        .status()
        .unwrap()
        .success());
    let spki_bytes = pem_unwrap(&std::fs::read_to_string(pub_path).unwrap());
    let point = &spki_bytes[spki_bytes.len() - 97..];
    let mut point_arr = [0u8; 97];
    point_arr.copy_from_slice(point);
    let their_public = p384::PublicKey::decode(&point_arr).expect("decode openssl p384 point");
    let (our_secret, _our_public) = p384::PrivateKey::generate();
    let our_shared = our_secret.ecdh(&their_public).expect("ecdh");
    // OpenSSL side: it needs our public key PEM to derive.
    let our_spki = spki_p384(&our_secret.public_key().encode_uncompressed());
    let our_pub_path = dir.join("dc-p384-ourpub.pem");
    std::fs::write(&our_pub_path, pem_wrap("PUBLIC KEY", &our_spki)).unwrap();
    let their_shared = Command::new("openssl")
        .args([
            "pkeyutl", "-derive", "-inkey", priv_path.to_str().unwrap(),
            "-peerkey", our_pub_path.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(their_shared.status.success(), "openssl derive failed: {}", String::from_utf8_lossy(&their_shared.stderr));
    assert_eq!(our_shared.as_slice(), their_shared.stdout.as_slice(), "P-384 ECDH secrets disagree");
}

fn trim_int(v: &[u8; 32]) -> Vec<u8> {
    let mut b: &[u8] = v;
    while b.len() > 1 && b[0] == 0 && b[1] & 0x80 == 0 {
        b = &b[1..];
    }
    if b[0] & 0x80 != 0 {
        let mut out = vec![0u8];
        out.extend(b);
        out
    } else {
        b.to_vec()
    }
}

fn to32(v: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let start = 32usize.saturating_sub(v.len());
    out[start..].copy_from_slice(&v[v.len().saturating_sub(32)..]);
    out
}

fn parse_der_sig(der: &[u8]) -> (Vec<u8>, Vec<u8>) {
    assert_eq!(der[0], 0x30);
    let mut pos = 2usize;
    if der[1] & 0x80 != 0 {
        pos += (der[1] & 0x7f) as usize;
    }
    let read = |pos: &mut usize| -> Vec<u8> {
        assert_eq!(der[*pos], 0x02);
        let len = der[*pos + 1] as usize;
        let v = der[*pos + 2..*pos + 2 + len].to_vec();
        *pos += 2 + len;
        // strip DER sign pad
        if v.len() > 1 && v[0] == 0 {
            v[1..].to_vec()
        } else {
            v
        }
    };
    let r = read(&mut pos);
    let s = read(&mut pos);
    (r, s)
}

fn spki_p256(point: &[u8; 65]) -> Vec<u8> {
    // SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING point }
    let mut out = vec![
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ];
    out.extend(point);
    out
}

fn spki_p384(point: &[u8; 97]) -> Vec<u8> {
    let mut out = vec![
        0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05,
        0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
    ];
    out.extend(point);
    out
}

fn pem_wrap(label: &str, der: &[u8]) -> String {
    let b64 = base64_encode(der);
    let mut out = format!("-----BEGIN {label}-----\n");
    for chunk in b64.as_bytes().chunks(64) {
        out.push_str(std::str::from_utf8(chunk).unwrap());
        out.push('\n');
    }
    out.push_str(&format!("-----END {label}-----\n"));
    out
}

fn pem_unwrap(pem: &str) -> Vec<u8> {
    let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
    base64_decode(body.trim())
}

fn base64_encode(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

fn base64_decode(s: &str) -> Vec<u8> {
    let mut vals = Vec::new();
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => continue,
        };
        vals.push(v);
    }
    let mut out = Vec::new();
    for chunk in vals.chunks(4) {
        let mut n: u32 = 0;
        for (i, v) in chunk.iter().enumerate() {
            n |= (*v as u32) << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    out
}

#[test]
fn tls12_client_handshakes_with_openssl_server() {
    // Reference TLS stack: `openssl s_server -www` (TLS 1.2
    // only, self-signed). Our hand-rolled client must complete
    // the handshake (verified chain against an explicit root
    // store holding the server cert) and exchange app data.
    if Command::new("openssl").arg("version").output().is_err() {
        eprintln!("skip: openssl CLI not available");
        return;
    }
    let dir = std::env::temp_dir();
    let cert = dir.join("dc-tls-cert.pem");
    let key = dir.join("dc-tls-key.pem");
    assert!(Command::new("openssl")
        .args([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", key.to_str().unwrap(), "-out", cert.to_str().unwrap(),
            "-days", "2", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ])
        .status()
        .unwrap()
        .success());
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let mut server = Command::new("openssl")
        .args([
            "s_server", "-accept", &port.to_string(),
            "-cert", cert.to_str().unwrap(), "-key", key.to_str().unwrap(),
            "-tls1_2", "-www", "-naccept", "1",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    // Wait for the listener.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let stream = loop {
        match std::net::TcpStream::connect(("127.0.0.1", port)) {
            Ok(s) => break s,
            Err(_) => {
                assert!(std::time::Instant::now() < deadline, "s_server did not start");
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    };
    let mut roots = dc_webrtc::tls12::RootStore::empty();
    roots.add_pem(&std::fs::read(&cert).unwrap());
    let (mut reader, mut writer) = dc_webrtc::tls12::connect_with_roots(
        stream,
        "localhost",
        false,
        Some(&roots),
    )
    .expect("TLS handshake with openssl s_server");
    use std::io::Read;
    writer.write_all(b"GET / HTTP/1.0\r\n\r\n").unwrap();
    let mut buf = [0u8; 4096];
    let n = reader.read(&mut buf).expect("read response");
    assert!(n > 0, "empty TLS response");
    let text = String::from_utf8_lossy(&buf[..n]);
    assert!(text.contains("HTTP/1.0 200"), "unexpected response: {text}");
    let _ = server.kill();
    let _ = server.wait();
}
