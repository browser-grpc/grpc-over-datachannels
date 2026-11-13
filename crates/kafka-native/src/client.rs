//! Minimal Kafka protocol client (async, dependency-free
//! beyond tokio + the crate's status type; TLS via rustls
//! behind the `kafka-tls` feature). Speaks flexible protocol
//! versions, negotiates via ApiVersions, and routes
//! group/transaction traffic to the coordinator broker.

use crate::codecs;
use crate::crypto;
use crate::wire::{crc32c, R, W};
use grpc_dc::Status;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Mutex;

pub const API_PRODUCE: i16 = 0;
pub const API_FETCH: i16 = 1;
pub const API_LIST_OFFSETS: i16 = 2;
pub const API_METADATA: i16 = 3;
pub const API_OFFSET_COMMIT: i16 = 8;
pub const API_OFFSET_FETCH: i16 = 9;
pub const API_FIND_COORDINATOR: i16 = 10;
pub const API_JOIN_GROUP: i16 = 11;
pub const API_HEARTBEAT: i16 = 12;
pub const API_LEAVE_GROUP: i16 = 13;
pub const API_SYNC_GROUP: i16 = 14;
pub const API_SASL_HANDSHAKE: i16 = 17;
pub const API_API_VERSIONS: i16 = 18;
pub const API_CREATE_TOPICS: i16 = 19;
pub const API_DELETE_TOPICS: i16 = 20;
pub const API_DELETE_RECORDS: i16 = 21;
pub const API_DESCRIBE_ACLS: i16 = 29;
pub const API_CREATE_ACLS: i16 = 30;
pub const API_DELETE_ACLS: i16 = 31;
pub const API_DESCRIBE_CONFIGS: i16 = 32;
pub const API_CREATE_PARTITIONS: i16 = 37;
pub const API_DELETE_GROUPS: i16 = 42;
pub const API_ALTER_CONFIGS: i16 = 44;
pub const API_LIST_GROUPS: i16 = 16;
pub const API_DESCRIBE_GROUPS: i16 = 15;
pub const API_OFFSET_DELETE: i16 = 47;
pub const API_LIST_TRANSACTIONS: i16 = 66;
pub const API_DESCRIBE_TRANSACTIONS: i16 = 65;
pub const API_CONSUMER_GROUP_HEARTBEAT: i16 = 68;
pub const API_CONSUMER_GROUP_DESCRIBE: i16 = 69;
pub const API_SHARE_GROUP_HEARTBEAT: i16 = 76;
pub const API_SHARE_GROUP_DESCRIBE: i16 = 77;
pub const API_SHARE_FETCH: i16 = 78;
pub const API_SHARE_ACKNOWLEDGE: i16 = 79;
pub const API_INIT_PRODUCER_ID: i16 = 22;
pub const API_ADD_PARTITIONS_TO_TXN: i16 = 24;
pub const API_ADD_OFFSETS_TO_TXN: i16 = 25;
pub const API_END_TXN: i16 = 26;
pub const API_TXN_OFFSET_COMMIT: i16 = 28;
pub const API_SASL_AUTHENTICATE: i16 = 36;

#[derive(Clone, Debug)]
pub enum SaslConfig {
    Plain { username: String, password: String },
    Scram { mechanism: String, username: String, password: String },
}

/// TLS to the broker (rustls; requires the `kafka-tls`
/// feature). Verification uses `ca_cert` (PEM file) unless
/// `insecure_skip_verify` is set.
#[derive(Clone, Debug)]
pub struct TlsConfig {
    pub ca_cert: Option<String>,
    pub server_name: Option<String>,
    pub insecure_skip_verify: bool,
}

#[derive(Clone, Debug)]
pub struct KafkaConfig {
    pub broker: String,
    pub client_id: String,
    pub sasl: Option<SaslConfig>,
    pub tls: Option<TlsConfig>,
}

/// Plain TCP or TLS stream to a broker.
enum Io {
    Plain(TcpStream),
    #[cfg(feature = "kafka-tls")]
    Tls(Box<tokio_rustls::client::TlsStream<TcpStream>>),
}

impl AsyncRead for Io {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match self.get_mut() {
            Io::Plain(s) => std::pin::Pin::new(s).poll_read(cx, buf),
            #[cfg(feature = "kafka-tls")]
            Io::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Io {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        data: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Io::Plain(s) => std::pin::Pin::new(s).poll_write(cx, data),
            #[cfg(feature = "kafka-tls")]
            Io::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_write(cx, data),
        }
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match self.get_mut() {
            Io::Plain(s) => std::pin::Pin::new(s).poll_flush(cx),
            #[cfg(feature = "kafka-tls")]
            Io::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_flush(cx),
        }
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        match self.get_mut() {
            Io::Plain(s) => std::pin::Pin::new(s).poll_shutdown(cx),
            #[cfg(feature = "kafka-tls")]
            Io::Tls(s) => std::pin::Pin::new(s.as_mut()).poll_shutdown(cx),
        }
    }
}

pub struct Conn {
    io: Io,
    corr: i32,
    /// True while a request may be in flight on `io`. Set
    /// before the write and cleared only after the full
    /// response is read. If the request future is dropped
    /// mid-flight (stream cancelled, timeout), the flag stays
    /// set and the next `request` reconnects first — reading
    /// on would consume the stale response and corrupt every
    /// following request on this connection.
    poisoned: bool,
    client_id: String,
    pub addr: String,
    sasl: Option<SaslConfig>,
    tls: Option<TlsConfig>,
    pub versions: HashMap<i16, (i16, i16)>,
}


/// Wrap a TCP stream in TLS (rustls). Without the `kafka-tls`
/// feature this reports an error.
#[cfg(feature = "kafka-tls")]
async fn tls_wrap(stream: TcpStream, addr: &str, tls: &TlsConfig) -> Result<Io, Status> {
    use rustls::pki_types::{CertificateDer, ServerName};
    let mut roots = rustls::RootCertStore::empty();
    if let Some(ca) = &tls.ca_cert {
        let pem = std::fs::read(ca).map_err(|e| bad(format!("kafka tls: read {ca}: {e}")))?;
        let mut reader = std::io::BufReader::new(pem.as_slice());
        let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut reader)
            .collect::<Result<_, _>>()
            .map_err(|e| bad(format!("kafka tls: parse {ca}: {e}")))?;
        for cert in certs {
            roots.add(cert).map_err(|e| bad(format!("kafka tls: ca: {e}")))?;
        }
    } else if !tls.insecure_skip_verify {
        return Err(bad("kafka tls: --tls-ca-cert or --tls-insecure-skip-verify is required"));
    }
    let builder = rustls::ClientConfig::builder();
    let mut config = if tls.insecure_skip_verify {
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerify))
            .with_no_client_auth()
    } else {
        builder.with_root_certificates(roots).with_no_client_auth()
    };
    config.alpn_protocols = vec![];
    let name = tls
        .server_name
        .clone()
        .unwrap_or_else(|| addr.rsplit(':').next_back().unwrap_or(addr).to_string());
    let server_name = ServerName::try_from(name)
        .map_err(|_| bad("kafka tls: invalid server name"))?;
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let stream = connector
        .connect(server_name, stream)
        .await
        .map_err(|e| bad(format!("kafka tls handshake {addr}: {e}")))?;
    Ok(Io::Tls(Box::new(stream)))
}

#[cfg(feature = "kafka-tls")]
#[derive(Debug)]
struct NoVerify;

#[cfg(feature = "kafka-tls")]
impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        use rustls::SignatureScheme::*;
        vec![
            RSA_PKCS1_SHA256, RSA_PKCS1_SHA384, RSA_PKCS1_SHA512,
            ECDSA_NISTP256_SHA256, ECDSA_NISTP384_SHA384, ECDSA_NISTP521_SHA512,
            RSA_PSS_SHA256, RSA_PSS_SHA384, RSA_PSS_SHA512, ED25519,
        ]
    }
}

#[cfg(not(feature = "kafka-tls"))]
async fn tls_wrap(_stream: TcpStream, _addr: &str, _tls: &TlsConfig) -> Result<Io, Status> {
    Err(bad("kafka tls: kafka_proxy was built without the `kafka-tls` feature"))
}

fn bad(msg: impl Into<String>) -> Status {
    Status::unavailable(msg.into())
}

impl Conn {
    pub async fn connect(addr: &str, client_id: &str, sasl: &Option<SaslConfig>, tls: &Option<TlsConfig>) -> Result<Conn, Status> {
        let stream = TcpStream::connect(addr)
            .await
            .map_err(|e| bad(format!("kafka connect {addr}: {e}")))?;
        let io = match tls {
            None => Io::Plain(stream),
            Some(tls) => tls_wrap(stream, addr, tls).await?,
        };
        let mut conn = Conn { io, corr: 0, poisoned: false, client_id: client_id.to_string(), addr: addr.to_string(), sasl: sasl.clone(), tls: tls.clone(), versions: HashMap::new() };
        // With SASL, authenticate first: some brokers (Redpanda)
        // reject ApiVersions on a SASL listener before the
        // handshake. SaslHandshake v1 / SaslAuthenticate v2 are
        // safe to send unnegotiated.
        if let Some(s) = sasl {
            conn.sasl_authenticate(s).await?;
        }
        conn.negotiate_versions().await?;
        Ok(conn)
    }

    fn next_corr(&mut self) -> i32 {
        self.corr += 1;
        self.corr
    }

    /// Re-establish the transport (TCP + optional TLS/SASL +
    /// ApiVersions) after the broker connection died — e.g. a
    /// broker restart. Pooled connections would otherwise stay
    /// broken forever.
    async fn reconnect(&mut self) -> Result<(), Status> {
        let stream = TcpStream::connect(&self.addr)
            .await
            .map_err(|e| bad(format!("kafka reconnect {}: {e}", self.addr)))?;
        self.io = match &self.tls {
            None => Io::Plain(stream),
            Some(tls) => tls_wrap(stream, &self.addr, tls).await?,
        };
        if let Some(s) = self.sasl.clone() {
            self.sasl_authenticate(&s).await?;
        }
        self.negotiate_versions().await
    }

    /// Send one request, read one response. On a transport
    /// error, reconnect once and retry (standard client
    /// behavior; the request may not have reached the broker).
    pub async fn request(&mut self, api_key: i16, version: i16, body: W, flexible: bool) -> Result<Vec<u8>, Status> {
        // A previous request future was dropped mid-flight:
        // its response may still be unread on this socket.
        // Reconnect so the stale bytes are discarded.
        if self.poisoned {
            self.reconnect().await?;
        }
        match self.request_once(api_key, version, &body, flexible).await {
            Ok(resp) => Ok(resp),
            Err(first) => {
                if std::env::var("KAFKA_DEBUG").is_ok() {
                    eprintln!("kafka req api={api_key} failed ({first}); reconnecting");
                }
                self.reconnect().await?;
                self.request_once(api_key, version, &body, flexible).await
            }
        }
    }

    async fn request_once(&mut self, api_key: i16, version: i16, body: &W, flexible: bool) -> Result<Vec<u8>, Status> {
        if std::env::var("KAFKA_DEBUG").is_ok() {
            eprintln!("kafka req api={api_key} ver={version} flex={flexible} len={}", body.0.len());
        }
        let corr = self.next_corr();
        self.poisoned = true;
        let mut frame = W::new();
        frame.i16(api_key);
        frame.i16(version);
        frame.i32(corr);
        frame.str16_opt(Some(&self.client_id));
        if flexible {
            frame.tagged_none();
        }
        frame.bytes(&body.0);
        let mut out = W::new();
        out.i32(frame.0.len() as i32);
        out.bytes(&frame.0);
        self.io.write_all(&out.0).await.map_err(|e| bad(format!("kafka write: {e}")))?;
        let mut len_buf = [0u8; 4];
        self.io.read_exact(&mut len_buf).await.map_err(|e| bad(format!("kafka read: {e}")))?;
        let len = i32::from_be_bytes(len_buf);
        if len < 4 || len > 512 * 1024 * 1024 {
            return Err(bad(format!("kafka: bad response length {len}")));
        }
        let mut buf = vec![0u8; len as usize];
        self.io.read_exact(&mut buf).await.map_err(|e| bad(format!("kafka read: {e}")))?;
        let mut r = R::new(&buf);
        let resp_corr = r.i32().map_err(bad)?;
        if resp_corr != corr {
            return Err(bad(format!("kafka: correlation mismatch {resp_corr} != {corr}")));
        }
        if flexible {
            r.skip_tagged().map_err(bad)?;
        }
        self.poisoned = false;
        Ok(buf[r.pos..].to_vec())
    }

    /// Pick (version, flexible): the flexible version when the
    /// broker supports it, else the legacy non-flexible one.
    pub fn pick(&self, api: i16, flex_ver: i16, legacy_ver: i16) -> Result<(i16, bool), Status> {
        match self.versions.get(&api) {
            Some(&(_min, max)) if max >= flex_ver => Ok((flex_ver, true)),
            Some(&(_min, max)) if max >= legacy_ver => Ok((legacy_ver, false)),
            Some(&(_min, max)) => Err(bad(format!(
                "kafka: api {api} version too old (broker max {max})"
            ))),
            None => Err(bad(format!("kafka: api {api} not advertised by broker"))),
        }
    }

    /// Like `supports`, but downgrades to the broker's max
    /// version instead of failing (e.g. Redpanda offers
    /// DescribeGroups v5, Apache Kafka v6). Callers must
    /// encode/parse for the returned version.
    pub fn negotiate(&self, api: i16, desired: i16) -> Result<i16, Status> {
        match self.versions.get(&api) {
            Some(&(_min, max)) => Ok(desired.min(max)),
            None => Err(bad(format!("kafka: api {api} not advertised by broker"))),
        }
    }

    pub fn has_api(&self, api: i16) -> bool {
        self.versions.contains_key(&api)
    }

    pub fn supports(&self, api: i16, desired: i16) -> Result<i16, Status> {
        match self.versions.get(&api) {
            Some(&(_min, max)) if max >= desired => Ok(desired),
            Some(&(_min, max)) => Err(bad(format!(
                "kafka: api {api} version {desired} unsupported (broker max {max})"
            ))),
            None => Err(bad(format!("kafka: api {api} not advertised by broker"))),
        }
    }

    async fn negotiate_versions(&mut self) -> Result<(), Status> {
        // ApiVersions v3 (flexible).
        let mut body = W::new();
        body.cstr("grpc-dc-kafka-proxy");
        body.cstr("1.0.0");
        body.tagged_none();
        match self.request_once(API_API_VERSIONS, 3, &body, true).await {
            Ok(resp) => {
                let mut r = R::new(&resp);
                let err = r.i16().map_err(bad)?;
                if err == 0 {
                    let n = r.carr_len().map_err(bad)?;
                    for _ in 0..n {
                        let key = r.i16().map_err(bad)?;
                        let min = r.i16().map_err(bad)?;
                        let max = r.i16().map_err(bad)?;
                        r.skip_tagged().map_err(bad)?;
                        self.versions.insert(key, (min, max));
                        if std::env::var("KAFKA_DEBUG").is_ok() && matches!(key, 10 | 22 | 24 | 25 | 26 | 28 | 11 | 14 | 36 | 37) {
                            eprintln!("apiversions api {key}: {min}..{max}");
                        }
                    }
                    return Ok(());
                }
            }
            Err(e) => {
                if std::env::var("KAFKA_DEBUG").is_ok() {
                    eprintln!("apiversions v3 failed: {e:?}, falling back to v0");
                }
            }
        }
        // Fall back to ApiVersions v0 (non-flexible).
        let body = W::new();
        let resp = self.request_once(API_API_VERSIONS, 0, &body, false).await?;
        let mut r = R::new(&resp);
        let err = r.i16().map_err(bad)?;
        if err != 0 {
            return Err(bad(format!("kafka: ApiVersions error {err}")));
        }
        let n = r.arr32().map_err(bad)?;
        for _ in 0..n.max(0) {
            let key = r.i16().map_err(bad)?;
            let min = r.i16().map_err(bad)?;
            let max = r.i16().map_err(bad)?;
            self.versions.insert(key, (min, max));
            if std::env::var("KAFKA_DEBUG").is_ok() && matches!(key, 10 | 22 | 24 | 25 | 26 | 28 | 11 | 14 | 36 | 37) {
                eprintln!("apiversions(v0) api {key}: {min}..{max}");
            }
        }
        Ok(())
    }

    async fn sasl_authenticate(&mut self, sasl: &SaslConfig) -> Result<(), Status> {
        let mechanism = match sasl {
            SaslConfig::Plain { .. } => "PLAIN".to_string(),
            SaslConfig::Scram { mechanism, .. } => mechanism.clone(),
        };
        // SaslHandshake v1 (non-flexible).
        let mut body = W::new();
        body.str16(&mechanism);
        let resp = self.request_once(API_SASL_HANDSHAKE, 1, &body, false).await?;
        let mut r = R::new(&resp);
        let err = r.i16().map_err(bad)?;
        if err != 0 {
            return Err(bad(format!("kafka: SASL handshake error {err}")));
        }
        match sasl {
            SaslConfig::Plain { username, password } => {
                let mut auth = Vec::new();
                auth.push(0);
                auth.extend_from_slice(username.as_bytes());
                auth.push(0);
                auth.extend_from_slice(password.as_bytes());
                self.sasl_authenticate_bytes(&auth).await.map(|_| ())
            }
            SaslConfig::Scram { mechanism, username, password } => {
                self.scram_authenticate(mechanism, username, password).await
            }
        }
    }

    async fn sasl_authenticate_bytes(&mut self, auth: &[u8]) -> Result<Vec<u8>, Status> {
        // SaslAuthenticate v2 (flexible).
        let mut body = W::new();
        body.cbytes(auth);
        body.tagged_none();
        let resp = self.request_once(API_SASL_AUTHENTICATE, 2, &body, true).await?;
        let mut r = R::new(&resp);
        let err = r.i16().map_err(bad)?;
        let msg = r.cstr_opt().map_err(bad)?;
        if err != 0 {
            return Err(bad(format!(
                "kafka: SASL authenticate error {err}: {}",
                msg.unwrap_or_default()
            )));
        }
        r.cbytes().map_err(bad)
    }

    async fn scram_authenticate(&mut self, mechanism: &str, username: &str, password: &str) -> Result<(), Status> {
        let sha512 = mechanism.ends_with("512");
        let nonce = make_nonce();
        let escaped_user = username.replace('=', "=3D").replace(',', "=2C");
        let client_first_bare = format!("n={escaped_user},r={nonce}");
        let client_first = format!("n,,{client_first_bare}");
        let server_first = self.sasl_authenticate_bytes(client_first.as_bytes()).await?;
        let server_first = String::from_utf8(server_first).map_err(|_| bad("kafka: scram bad server-first"))?;
        let mut server_nonce = None;
        let mut salt_b64 = None;
        let mut iterations = 0u32;
        for part in server_first.split(',') {
            if let Some(v) = part.strip_prefix("r=") {
                server_nonce = Some(v.to_string());
            } else if let Some(v) = part.strip_prefix("s=") {
                salt_b64 = Some(v.to_string());
            } else if let Some(v) = part.strip_prefix("i=") {
                iterations = v.parse().map_err(|_| bad("kafka: scram bad iterations"))?;
            }
        }
        let server_nonce = server_nonce.ok_or_else(|| bad("kafka: scram missing nonce"))?;
        if !server_nonce.starts_with(&nonce) {
            return Err(bad("kafka: scram nonce mismatch"));
        }
        let salt = b64_decode(&salt_b64.ok_or_else(|| bad("kafka: scram missing salt"))?);
        let salted: Vec<u8> = if sha512 {
            crypto::pbkdf2_hmac_sha512(password.as_bytes(), &salt, iterations, 64)
        } else {
            crypto::pbkdf2_hmac_sha256(password.as_bytes(), &salt, iterations, 32)
        };
        let client_key = hmac_dyn(sha512, &salted, b"Client Key");
        let stored_key = hash_dyn(sha512, &client_key);
        let client_final_wo_proof = format!("c=biws,r={server_nonce}");
        let auth_message = format!("{client_first_bare},{server_first},{client_final_wo_proof}");
        let client_signature = hmac_dyn(sha512, &stored_key, auth_message.as_bytes());
        let proof: Vec<u8> = client_key.iter().zip(client_signature.iter()).map(|(a, b)| a ^ b).collect();
        let client_final = format!("{client_final_wo_proof},p={}", b64_encode(&proof));
        let server_final = self.sasl_authenticate_bytes(client_final.as_bytes()).await?;
        let server_final = String::from_utf8(server_final).map_err(|_| bad("kafka: scram bad server-final"))?;
        let server_key = hmac_dyn(sha512, &salted, b"Server Key");
        let expected = b64_encode(&hmac_dyn(sha512, &server_key, auth_message.as_bytes()));
        for part in server_final.split(',') {
            if let Some(v) = part.strip_prefix("e=") {
                return Err(bad(format!("kafka: scram server error {v}")));
            }
            if let Some(v) = part.strip_prefix("v=") {
                if v != expected {
                    return Err(bad("kafka: scram server signature mismatch"));
                }
            }
        }
        Ok(())
    }
}

fn hash_dyn(sha512: bool, data: &[u8]) -> Vec<u8> {
    if sha512 {
        crypto::sha512(data).to_vec()
    } else {
        crypto::sha256(data).to_vec()
    }
}

fn hmac_dyn(sha512: bool, key: &[u8], msg: &[u8]) -> Vec<u8> {
    if sha512 {
        crypto::hmac_sha512(key, msg).to_vec()
    } else {
        crypto::hmac_sha256(key, msg).to_vec()
    }
}

/// Client-generated member id for KIP-932 share groups: a
/// Kafka Uuid (16 bytes from a SHA-256 seed, base64url, no
/// padding; 22 chars).
fn make_share_member_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let seed = format!("share-member:{now}:{}:{n}", std::process::id());
    let digest = crypto::sha256(seed.as_bytes());
    const ALPHABET: &[u8] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let data = &digest[..16];
    let mut out = String::with_capacity(22);
    for chunk in data.chunks(3) {
        let mut n3 = [0u8; 3];
        n3[..chunk.len()].copy_from_slice(chunk);
        let v = ((n3[0] as u32) << 16) | ((n3[1] as u32) << 8) | n3[2] as u32;
        out.push(ALPHABET[(v >> 18) as usize & 63] as char);
        out.push(ALPHABET[(v >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(v >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[v as usize & 63] as char);
        }
    }
    out
}

fn make_nonce() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let seed = now ^ (std::process::id() as u128) << 64;
    let digest = crypto::sha256(&seed.to_be_bytes());
    b64_encode(&digest[..18])
}

pub fn b64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let mut n = [0u8; 3];
        n[..chunk.len()].copy_from_slice(chunk);
        let v = ((n[0] as u32) << 16) | ((n[1] as u32) << 8) | n[2] as u32;
        out.push(ALPHABET[(v >> 18) as usize & 63] as char);
        out.push(ALPHABET[(v >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ALPHABET[(v >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ALPHABET[v as usize & 63] as char } else { '=' });
    }
    out
}

pub fn b64_decode(s: &str) -> Vec<u8> {
    fn val(c: u8) -> u8 {
        match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => 0,
        }
    }
    let bytes: Vec<u8> = s.bytes().filter(|&c| c != b'=').collect();
    let mut out = Vec::new();
    for chunk in bytes.chunks(4) {
        let mut v: u32 = 0;
        for (i, &c) in chunk.iter().enumerate() {
            v |= (val(c) as u32) << (18 - 6 * i);
        }
        out.push((v >> 16) as u8);
        if chunk.len() > 2 {
            out.push((v >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(v as u8);
        }
    }
    out
}

/// Shared broker handle: connection pool keyed by broker
/// address, with coordinator routing for groups/transactions.
pub struct Broker {
    cfg: KafkaConfig,
    conns: Mutex<HashMap<String, Arc<Mutex<Conn>>>>,
}

impl Broker {
    pub fn new(cfg: KafkaConfig) -> Broker {
        Broker { cfg, conns: Mutex::new(HashMap::new()) }
    }

    pub async fn conn_for(&self, addr: &str) -> Result<Arc<Mutex<Conn>>, Status> {
        let mut map = self.conns.lock().await;
        if let Some(c) = map.get(addr) {
            return Ok(c.clone());
        }
        let conn = Conn::connect(addr, &self.cfg.client_id, &self.cfg.sasl, &self.cfg.tls).await?;
        let arc = Arc::new(Mutex::new(conn));
        map.insert(addr.to_string(), arc.clone());
        Ok(arc)
    }

    pub async fn bootstrap(&self) -> Result<Arc<Mutex<Conn>>, Status> {
        self.conn_for(&self.cfg.broker.clone()).await
    }

    /// Like `coordinator`, but returns a brand-new connection
    /// that is NOT pooled. Group members must each own their
    /// coordinator connection: a JoinGroup parked by the
    /// broker during a rebalance would otherwise hold the
    /// shared connection mutex and starve every other
    /// member's heartbeat until its session expires.
    pub async fn coordinator_fresh(&self, key: &str, key_type: i8) -> Result<Arc<Mutex<Conn>>, Status> {
        let pooled = self.coordinator(key, key_type).await?;
        let addr = {
            let conn = pooled.lock().await;
            conn.addr.clone()
        };
        let conn = Conn::connect(&addr, &self.cfg.client_id, &self.cfg.sasl, &self.cfg.tls).await?;
        Ok(Arc::new(Mutex::new(conn)))
    }

    /// FindCoordinator (key_type 0=group, 1=transaction) then
    /// return a connection to that coordinator.
    pub async fn coordinator(&self, key: &str, key_type: i8) -> Result<Arc<Mutex<Conn>>, Status> {
        let boot = self.bootstrap().await?;
        // FindCoordinator, retrying while the coordinator is
        // loading (errors 14/15 are transient on a fresh group).
        let mut addr = None;
        for attempt in 0..20 {
            let mut conn = boot.lock().await;
            let ver = conn.supports(API_FIND_COORDINATOR, 4)?;
            // v4: KeyType, then CoordinatorKeys array.
            let mut body = W::new();
            body.i8(key_type);
            body.carr(1);
            body.cstr(key);
            body.tagged_none();
            let resp = conn.request(API_FIND_COORDINATOR, ver, body, true).await?;
            let mut r = R::new(&resp);
            let _throttle = r.i32().map_err(bad)?;
            let n = r.carr_len().map_err(bad)?;
            let mut found = None;
            let mut last_err = 0i32;
            for _ in 0..n {
                let _key = r.cstr().map_err(bad)?;
                let _node = r.i32().map_err(bad)?;
                let host = r.cstr().map_err(bad)?;
                let port = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                let _msg = r.cstr_opt().map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
                if err == 0 {
                    found = Some(format!("{host}:{port}"));
                } else {
                    last_err = err;
                }
            }
            match found {
                Some(a) => {
                    addr = Some(a);
                    break;
                }
                None if matches!(last_err, 14 | 15 | 16) && attempt < 19 => {
                    drop(conn);
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                }
                None => {
                    return Err(bad(format!("kafka: FindCoordinator error {last_err}")));
                }
            }
        }
        let addr = addr.ok_or_else(|| bad("kafka: FindCoordinator empty response"))?;
        // Coordinator host is the broker's internal advertised
        // host; when the proxy runs beside the broker (tests,
        // containers) it resolves directly. If it is the same
        // bootstrap address this reuses the pooled connection.
        if addr == self.cfg.broker {
            return self.bootstrap().await;
        }
        match self.conn_for(&addr).await {
            Ok(c) => Ok(c),
            Err(_) => {
                // Advertised coordinator unreachable (e.g. a
                // container-internal name); the bootstrap broker
                // of a single-node cluster is the coordinator.
                self.bootstrap().await
            }
        }
    }

    /// Connection to the partition leader, discovered through
    /// metadata. Falls back to the bootstrap broker when the
    /// leader is unknown or its advertised address is unreachable
    /// (single-broker clusters and container-internal names).
    pub async fn leader_conn(
        &self,
        topic: &str,
        partition: i32,
    ) -> Result<Arc<Mutex<Conn>>, Status> {
        let boot = self.bootstrap().await?;
        if partition < 0 {
            return Ok(boot);
        }
        let meta = self.metadata(vec![topic.to_string()], false).await?;
        let leader_id = meta
            .topics
            .iter()
            .find(|t| t.name == topic)
            .and_then(|t| t.partitions.iter().find(|p| p.id == partition))
            .map(|p| p.leader_id)
            .unwrap_or(-1);
        if leader_id < 0 {
            return Ok(boot);
        }
        let Some(broker) = meta.brokers.iter().find(|b| b.node_id == leader_id) else {
            return Ok(boot);
        };
        let addr = format!("{}:{}", broker.host, broker.port);
        if addr == self.cfg.broker {
            return Ok(boot);
        }
        match self.conn_for(&addr).await {
            Ok(conn) => Ok(conn),
            Err(_) => Ok(boot),
        }
    }

    pub async fn metadata(
        &self,
        topics: Vec<String>,
        allow_auto_create: bool,
    ) -> Result<crate::pb::MetadataResponse, Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_METADATA, 9)?;
        let mut body = W::new();
        if topics.is_empty() {
            body.uvarint(0); // null topics array = all
        } else {
            body.carr(topics.len());
            for t in &topics {
                body.cstr(t); // v9 topic struct: name + tagged fields
                body.tagged_none();
            }
        }
        body.i8(allow_auto_create as i8);
        body.i8(0); // include_cluster_authorized_ops
        body.i8(0); // include_topic_authorized_ops
        body.tagged_none();
        let resp = conn.request(API_METADATA, ver, body, true).await?;
        let mut r = R::new(&resp);
        let mut out = crate::pb::MetadataResponse::default();
        out.throttle_time_ms = r.i32().map_err(bad)?;
        let nb = r.carr_len().map_err(bad)?;
        for _ in 0..nb {
            let mut b = crate::pb::BrokerMetadata::default();
            b.node_id = r.i32().map_err(bad)?;
            b.host = r.cstr().map_err(bad)?;
            b.port = r.i32().map_err(bad)?;
            b.rack = r.cstr_opt().map_err(bad)?.unwrap_or_default();
            r.skip_tagged().map_err(bad)?;
            out.brokers.push(b);
        }
        out.cluster_id = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        out.controller_id = r.i32().map_err(bad)?;
        let nt = r.carr_len().map_err(bad)?;
        for _ in 0..nt {
            let mut t = crate::pb::TopicMetadata::default();
            t.error_code = r.i16().map_err(bad)? as i32;
            t.name = r.cstr_opt().map_err(bad)?.unwrap_or_default();
            t.is_internal = r.i8().map_err(bad)? != 0;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let mut p = crate::pb::PartitionMetadata::default();
                p.error_code = r.i16().map_err(bad)? as i32;
                p.id = r.i32().map_err(bad)?;
                p.leader_id = r.i32().map_err(bad)?;
                p.leader_epoch = r.i32().map_err(bad)?;
                let nr = r.carr_len().map_err(bad)?;
                for _ in 0..nr {
                    p.replicas.push(r.i32().map_err(bad)?);
                }
                let ni = r.carr_len().map_err(bad)?;
                for _ in 0..ni {
                    p.isr.push(r.i32().map_err(bad)?);
                }
                let _offline = r.carr_len().map_err(bad)?;
                r.take(_offline * 4).map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
                t.partitions.push(p);
            }
            let _ops = r.i32().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
            out.topics.push(t);
        }
        Ok(out)
    }

    pub async fn create_topics(
        &self,
        topics: Vec<(String, i32, i32)>,
        timeout_ms: i32,
        validate_only: bool,
    ) -> Result<Vec<(String, i32)>, Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_CREATE_TOPICS, 5)?;
        let mut body = W::new();
        body.carr(topics.len());
        for (name, partitions, rf) in &topics {
            body.cstr(name);
            body.i32(*partitions);
            body.i16(*rf as i16);
            body.carr(0); // assignments
            body.carr(0); // configs
            body.tagged_none();
        }
        body.i32(timeout_ms);
        body.i8(validate_only as i8);
        body.tagged_none();
        let resp = conn.request(API_CREATE_TOPICS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut out = Vec::new();
        for _ in 0..n {
            let name = r.cstr().map_err(bad)?;
            let err = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            let _np = r.i32().map_err(bad)?;
            let _rf = r.i16().map_err(bad)?;
            let nconfigs = r.carr_len().map_err(bad)?;
            for _ in 0..nconfigs {
                let _cfg_name = r.cstr().map_err(bad)?;
                let _cfg_value = r.cstr_opt().map_err(bad)?;
                let _cfg_readonly = r.i8().map_err(bad)?;
                let _cfg_source = r.i8().map_err(bad)?;
                let _cfg_sensitive = r.i8().map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
            }
            r.skip_tagged().map_err(bad)?;
            out.push((name, err));
        }
        Ok(out)
    }

    // --- Admin operations (Kafka admin APIs; error codes pass
    // through to the gRPC response fields) ---

    pub async fn describe_configs(
        &self,
        resource_type: i8,
        resource_name: &str,
        keys: &[String],
        synonyms: bool,
    ) -> Result<(i32, Vec<crate::pb::ConfigValue>), Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_DESCRIBE_CONFIGS, 4)?;
        let mut body = W::new();
        body.carr(1);
        body.i8(resource_type);
        body.cstr(resource_name);
        if keys.is_empty() {
            body.uvarint(0); // null ConfigurationKeys = all
        } else {
            body.carr(keys.len());
            for k in keys {
                body.cstr(k);
            }
        }
        body.tagged_none();
        body.i8(synonyms as i8);
        body.i8(0); // IncludeDocumentation (v3+)
        body.tagged_none();
        let resp = conn.request(API_DESCRIBE_CONFIGS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut error_code = 0i32;
        let mut values = Vec::new();
        for _ in 0..n {
            error_code = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            let _rtype = r.i8().map_err(bad)?;
            let _rname = r.cstr().map_err(bad)?;
            let ncfg = r.carr_len().map_err(bad)?;
            for _ in 0..ncfg {
                let name = r.cstr().map_err(bad)?;
                let value = r.cstr_opt().map_err(bad)?.unwrap_or_default();
                let read_only = r.i8().map_err(bad)? != 0;
                let source = r.i8().map_err(bad)? as i32;
                let is_sensitive = r.i8().map_err(bad)? != 0;
                let nsyn = r.carr_len().map_err(bad)?;
                for _ in 0..nsyn {
                    let _sn = r.cstr().map_err(bad)?;
                    let _sv = r.cstr_opt().map_err(bad)?;
                    let _ss = r.i8().map_err(bad)?;
                    r.skip_tagged().map_err(bad)?;
                }
                let _docs = r.cstr_opt().map_err(bad)?; // Documentation (v4)
                r.skip_tagged().map_err(bad)?;
                values.push(crate::pb::ConfigValue {
                    name,
                    value,
                    read_only,
                    source,
                    is_sensitive,
                    ..Default::default()
                });
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok((error_code, values))
    }

    pub async fn alter_configs(
        &self,
        resource_type: i8,
        resource_name: &str,
        entries: &[(String, String, i8)],
        validate_only: bool,
    ) -> Result<i32, Status> {
        // IncrementalAlterConfigs (44) v1.
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(44, 1)?;
        let mut body = W::new();
        body.carr(1);
        body.i8(resource_type);
        body.cstr(resource_name);
        body.carr(entries.len());
        for (name, value, op) in entries {
            body.cstr(name);
            body.i8(*op);
            if *op == 1 {
                body.cstr_opt(None);
            } else {
                body.cstr_opt(Some(value));
            }
            body.tagged_none();
        }
        body.tagged_none();
        body.i8(validate_only as i8);
        body.tagged_none();
        let resp = conn.request(44, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut error_code = 0i32;
        for _ in 0..n {
            error_code = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            let _rtype = r.i8().map_err(bad)?;
            let _rname = r.cstr().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        Ok(error_code)
    }

    pub async fn create_partitions(
        &self,
        topic: &str,
        total_count: i32,
        validate_only: bool,
        timeout_ms: i32,
    ) -> Result<i32, Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_CREATE_PARTITIONS, 3)?;
        let timeout = if timeout_ms > 0 { timeout_ms } else { 30_000 };
        let mut body = W::new();
        body.carr(1);
        body.cstr(topic);
        body.i32(total_count);
        body.uvarint(0); // null assignment
        body.tagged_none();
        body.i32(timeout);
        body.i8(validate_only as i8);
        body.tagged_none();
        let resp = conn.request(API_CREATE_PARTITIONS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut error_code = 0i32;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            error_code = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        Ok(error_code)
    }

    pub async fn delete_records(
        &self,
        topic: &str,
        partition: i32,
        before_offset: i64,
    ) -> Result<(i64, i32), Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_DELETE_RECORDS, 2)?;
        let mut body = W::new();
        body.carr(1);
        body.cstr(topic);
        body.carr(1);
        body.i32(partition);
        body.i64(before_offset);
        body.tagged_none();
        body.tagged_none();
        body.i32(30_000);
        body.tagged_none();
        let resp = conn.request(API_DELETE_RECORDS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let ntopics = r.carr_len().map_err(bad)?;
        let mut out = (0i64, 0i32);
        for _ in 0..ntopics {
            let _name = r.cstr().map_err(bad)?;
            let nparts = r.carr_len().map_err(bad)?;
            for _ in 0..nparts {
                let _p = r.i32().map_err(bad)?;
                let low = r.i64().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                r.skip_tagged().map_err(bad)?;
                out = (low, err);
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok(out)
    }

    pub async fn list_groups(&self) -> Result<(i32, Vec<crate::pb::GroupListing>), Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        // v4 adds StatesFilter + flexible encoding, v5 adds
        // TypesFilter + GroupType (Redpanda stops at v4).
        let ver = conn.negotiate(API_LIST_GROUPS, 5)?;
        let flexible = ver >= 4;
        let mut body = W::new();
        if ver >= 4 {
            body.carr(0); // StatesFilter: empty
        }
        if ver >= 5 {
            body.carr(0); // TypesFilter: empty
        }
        if flexible {
            body.tagged_none();
        }
        let resp = conn.request(API_LIST_GROUPS, ver, body, flexible).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        let n = if flexible { r.carr_len().map_err(bad)? } else { r.arr32().map_err(bad)?.max(0) as usize };
        let mut groups = Vec::new();
        for _ in 0..n {
            let (group_id, protocol_type) = if flexible {
                (r.cstr().map_err(bad)?, r.cstr().map_err(bad)?)
            } else {
                (r.str16().map_err(bad)?, r.str16().map_err(bad)?)
            };
            let group_state = if ver >= 1 {
                if flexible { r.cstr().map_err(bad)? } else { r.str16().map_err(bad)? }
            } else {
                String::new()
            };
            if ver >= 5 {
                let _group_type = r.cstr().map_err(bad)?;
            }
            if flexible {
                r.skip_tagged().map_err(bad)?;
            }
            groups.push(crate::pb::GroupListing {
                group_id,
                protocol_type,
                group_state,
                ..Default::default()
            });
        }
        Ok((error_code, groups))
    }

    pub async fn describe_groups(
        &self,
        group_ids: &[String],
    ) -> Result<Vec<crate::pb::DescribedGroup>, Status> {
        // One coordinator round per group (coordinators may
        // differ); results stay aligned with the request order.
        let mut out = Vec::new();
        for group_id in group_ids {
            out.push(self.describe_one_group(group_id).await?);
        }
        Ok(out)
    }

    async fn describe_one_group(&self, group_id: &str) -> Result<crate::pb::DescribedGroup, Status> {
        let coord = match self.coordinator(group_id, 0).await {
            Ok(c) => c,
            Err(_) => {
                return Ok(crate::pb::DescribedGroup {
                    group_id: group_id.to_string(),
                    error_code: 69, // GROUP_ID_NOT_FOUND-ish transport failure
                    ..Default::default()
                })
            }
        };
        let described = self.describe_classic_group(&coord, group_id).await?;
        // A group living under the KIP-848 consumer protocol is
        // invisible to classic DescribeGroups (GROUP_ID_NOT_FOUND);
        // describe it through ConsumerGroupDescribe instead.
        if described.error_code == 69
            && coord.lock().await.has_api(API_CONSUMER_GROUP_DESCRIBE)
        {
            if let Ok(consumer) = self.describe_consumer_group(&coord, group_id).await {
                if consumer.error_code == 0 {
                    return Ok(consumer);
                }
            }
        }
        Ok(described)
    }

    async fn describe_classic_group(
        &self,
        coord: &Arc<Mutex<Conn>>,
        group_id: &str,
    ) -> Result<crate::pb::DescribedGroup, Status> {
        let mut conn = coord.lock().await;
        // v6 adds ErrorMessage; v5 (Redpanda's max) has the
        // same flexible layout without it.
        let ver = conn.negotiate(API_DESCRIBE_GROUPS, 6)?;
        if ver < 5 {
            return Err(bad(format!(
                "kafka: api {API_DESCRIBE_GROUPS} version too old (broker max {ver})"
            )));
        }
        let mut body = W::new();
        body.carr(1);
        body.cstr(group_id);
        body.i8(0); // IncludeAuthorizedOperations
        body.tagged_none();
        let resp = conn.request(API_DESCRIBE_GROUPS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut described = crate::pb::DescribedGroup {
            group_id: group_id.to_string(),
            ..Default::default()
        };
        for _ in 0..n {
            described.error_code = r.i16().map_err(bad)? as i32;
            if ver >= 6 {
                // ErrorMessage is only on the wire from v6.
                let _msg = r.cstr_opt().map_err(bad)?;
            }
            described.group_id = r.cstr().map_err(bad)?;
            described.group_state = r.cstr().map_err(bad)?;
            described.protocol_type = r.cstr().map_err(bad)?;
            described.protocol = r.cstr().map_err(bad)?;
            let nmembers = r.carr_len().map_err(bad)?;
            for _ in 0..nmembers {
                let member_id = r.cstr().map_err(bad)?;
                let _instance = r.cstr_opt().map_err(bad)?;
                let client_id = r.cstr().map_err(bad)?;
                let client_host = r.cstr().map_err(bad)?;
                let _metadata = r.cbytes().map_err(bad)?;
                let assignment = r.cbytes().map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
                described.members.push(crate::pb::GroupMember {
                    member_id,
                    client_id,
                    client_host,
                    assignment: decode_assignment(&assignment)
                        .into_iter()
                        .map(|(topic, partition)| crate::pb::TopicPartition {
                            topic,
                            partition,
                            ..Default::default()
                        })
                        .collect(),
                    ..Default::default()
                });
            }
            let _authorized = r.i32().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        Ok(described)
    }

    pub async fn delete_groups(&self, group_ids: &[String]) -> Result<Vec<(String, i32)>, Status> {
        let mut out = Vec::new();
        for group_id in group_ids {
            let err = self.delete_one_group(group_id).await?;
            out.push((group_id.clone(), err));
        }
        Ok(out)
    }

    async fn delete_one_group(&self, group_id: &str) -> Result<i32, Status> {
        let coord = self.coordinator(group_id, 0).await?;
        let mut conn = coord.lock().await;
        let ver = conn.supports(API_DELETE_GROUPS, 2)?;
        let mut body = W::new();
        body.carr(1);
        body.cstr(group_id);
        body.tagged_none();
        let resp = conn.request(API_DELETE_GROUPS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut error_code = 0i32;
        for _ in 0..n {
            let _gid = r.cstr().map_err(bad)?;
            error_code = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        Ok(error_code)
    }

    pub async fn delete_group_offsets(
        &self,
        group: &str,
        topic: &str,
        partitions: &[i32],
    ) -> Result<i32, Status> {
        // OffsetDelete (47) v0: NOT flexible (header v1).
        let coord = self.coordinator(group, 0).await?;
        let mut conn = coord.lock().await;
        let mut body = W::new();
        body.str16(group);
        body.arr32(1);
        body.str16(topic);
        body.arr32(partitions.len());
        for p in partitions {
            body.i32(*p);
        }
        let resp = conn.request(API_OFFSET_DELETE, 0, body, false).await?;
        let mut r = R::new(&resp);
        // OffsetDelete's v0 response puts the top-level error
        // code BEFORE the throttle time (unlike most APIs).
        let mut error_code = r.i16().map_err(bad)? as i32;
        let _throttle = r.i32().map_err(bad)?;
        let ntopics = r.arr32().map_err(bad)?;
        for _ in 0..ntopics.max(0) {
            let _name = r.str16().map_err(bad)?;
            let nparts = r.arr32().map_err(bad)?;
            for _ in 0..nparts.max(0) {
                let _p = r.i32().map_err(bad)?;
                let perr = r.i16().map_err(bad)? as i32;
                if error_code == 0 {
                    error_code = perr;
                }
            }
        }
        Ok(error_code)
    }

    fn acl_fields(body: &mut W, acl: &crate::pb::Acl) {
        body.i8(acl.resource_type as i8);
        if acl.resource_name.is_empty() {
            body.cstr_opt(None);
        } else {
            body.cstr_opt(Some(acl.resource_name.as_str()));
        }
        body.i8(acl.pattern_type as i8);
        if acl.principal.is_empty() {
            body.cstr_opt(None);
        } else {
            body.cstr_opt(Some(acl.principal.as_str()));
        }
        if acl.host.is_empty() {
            body.cstr_opt(None);
        } else {
            body.cstr_opt(Some(acl.host.as_str()));
        }
        body.i8(acl.operation as i8);
        body.i8(acl.permission_type as i8);
    }

    pub async fn describe_acls(
        &self,
        filter: &crate::pb::Acl,
    ) -> Result<(i32, Vec<crate::pb::Acl>), Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_DESCRIBE_ACLS, 3)?;
        let mut body = W::new();
        Self::acl_fields(&mut body, filter);
        body.tagged_none();
        let resp = conn.request(API_DESCRIBE_ACLS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        let _msg = r.cstr_opt().map_err(bad)?;
        let nres = r.carr_len().map_err(bad)?;
        let mut acls = Vec::new();
        for _ in 0..nres {
            let resource_type = r.i8().map_err(bad)? as i32;
            let resource_name = r.cstr().map_err(bad)?;
            let pattern_type = r.i8().map_err(bad)? as i32;
            let nacl = r.carr_len().map_err(bad)?;
            for _ in 0..nacl {
                let principal = r.cstr().map_err(bad)?;
                let host = r.cstr().map_err(bad)?;
                let operation = r.i8().map_err(bad)? as i32;
                let permission_type = r.i8().map_err(bad)? as i32;
                r.skip_tagged().map_err(bad)?;
                acls.push(crate::pb::Acl {
                    resource_type,
                    resource_name: resource_name.clone(),
                    pattern_type,
                    principal,
                    host,
                    operation,
                    permission_type,
                    ..Default::default()
                });
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok((error_code, acls))
    }

    pub async fn create_acls(&self, acls: &[crate::pb::Acl]) -> Result<Vec<i32>, Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_CREATE_ACLS, 3)?;
        let mut body = W::new();
        body.carr(acls.len());
        for acl in acls {
            // Creation shape: ResourceName/Principal/Host are
            // non-nullable compact strings here.
            body.i8(acl.resource_type as i8);
            body.cstr(&acl.resource_name);
            body.i8(acl.pattern_type as i8);
            body.cstr(&acl.principal);
            body.cstr(&acl.host);
            body.i8(acl.operation as i8);
            body.i8(acl.permission_type as i8);
            body.tagged_none();
        }
        body.tagged_none();
        let resp = conn.request(API_CREATE_ACLS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut out = Vec::new();
        for _ in 0..n {
            out.push(r.i16().map_err(bad)? as i32);
            let _msg = r.cstr_opt().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        Ok(out)
    }

    pub async fn delete_acls(&self, filters: &[crate::pb::Acl]) -> Result<Vec<i32>, Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_DELETE_ACLS, 3)?;
        let mut body = W::new();
        body.carr(filters.len());
        for filter in filters {
            Self::acl_fields(&mut body, filter);
            body.tagged_none();
        }
        body.tagged_none();
        let resp = conn.request(API_DELETE_ACLS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut out = Vec::new();
        for _ in 0..n {
            out.push(r.i16().map_err(bad)? as i32);
            let _msg = r.cstr_opt().map_err(bad)?;
            let nmatch = r.carr_len().map_err(bad)?;
            for _ in 0..nmatch {
                let _e = r.i16().map_err(bad)?;
                let _m = r.cstr_opt().map_err(bad)?;
                let _p = r.cstr().map_err(bad)?;
                let _h = r.cstr().map_err(bad)?;
                let _o = r.i8().map_err(bad)?;
                let _pt = r.i8().map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok(out)
    }

    pub async fn list_transactions(
        &self,
    ) -> Result<(i32, Vec<crate::pb::TransactionListing>), Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        // ListTransactions is v0 on some brokers (Apache Kafka
        // 4.3 advertises max 0); v1 only adds DurationFilter.
        let ver = match conn.versions.get(&API_LIST_TRANSACTIONS) {
            Some(&(_min, max)) => max.min(1),
            None => return Err(bad("kafka: api 65 not advertised by broker")),
        };
        let mut body = W::new();
        body.carr(0); // StateFilter
        body.carr(0); // ProducerIdFilter
        if ver >= 1 {
            body.i64(-1); // DurationFilter (<0 = no bound)
        }
        body.tagged_none();
        let resp = conn.request(API_LIST_TRANSACTIONS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        // UnknownStateFilters (echoed unrecognized state
        // filters) precedes the transaction states.
        let n_unknown = r.carr_len().map_err(bad)?;
        for _ in 0..n_unknown {
            let _state = r.cstr().map_err(bad)?;
        }
        let n = r.carr_len().map_err(bad)?;
        let mut out = Vec::new();
        for _ in 0..n {
            let transactional_id = r.cstr().map_err(bad)?;
            let producer_id = r.i64().map_err(bad)?;
            let transaction_state = r.cstr().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
            out.push(crate::pb::TransactionListing {
                transactional_id,
                producer_id,
                transaction_state,
                ..Default::default()
            });
        }
        Ok((error_code, out))
    }

    pub async fn describe_transactions(
        &self,
        transactional_ids: &[String],
    ) -> Result<Vec<crate::pb::DescribedTransaction>, Status> {
        let mut out = Vec::new();
        for tid in transactional_ids {
            out.push(self.describe_one_transaction(tid).await?);
        }
        Ok(out)
    }

    async fn describe_one_transaction(
        &self,
        tid: &str,
    ) -> Result<crate::pb::DescribedTransaction, Status> {
        let mut described = crate::pb::DescribedTransaction {
            transactional_id: tid.to_string(),
            ..Default::default()
        };
        let coord = match self.coordinator(tid, 1).await {
            Ok(c) => c,
            Err(_) => {
                described.error_code = 69;
                return Ok(described);
            }
        };
        let mut conn = coord.lock().await;
        let ver = conn.supports(API_DESCRIBE_TRANSACTIONS, 0)?;
        let mut body = W::new();
        body.carr(1);
        body.cstr(tid);
        body.tagged_none();
        let resp = conn.request(API_DESCRIBE_TRANSACTIONS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            // TransactionState wire order: error, transactional
            // id, state, timeout, start time, producer id/epoch.
            described.error_code = r.i16().map_err(bad)? as i32;
            described.transactional_id = r.cstr().map_err(bad)?;
            described.transaction_state = r.cstr().map_err(bad)?;
            let _timeout_ms = r.i32().map_err(bad)?;
            described.last_update_timestamp_ms = r.i64().map_err(bad)?;
            described.producer_id = r.i64().map_err(bad)?;
            described.producer_epoch = r.i16().map_err(bad)? as i32;
            let ntopics = r.carr_len().map_err(bad)?;
            for _ in 0..ntopics {
                let _t = r.cstr().map_err(bad)?;
                let nparts = r.carr_len().map_err(bad)?;
                for _ in 0..nparts {
                    let _p = r.i32().map_err(bad)?;
                }
                r.skip_tagged().map_err(bad)?;
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok(described)
    }

    pub async fn delete_topics(&self, topics: Vec<String>, timeout_ms: i32) -> Result<Vec<(String, i32)>, Status> {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_DELETE_TOPICS, 4)?;
        let mut body = W::new();
        body.carr(topics.len());
        for t in &topics {
            body.cstr(t); // v4: TopicNames is a plain string array
        }
        body.i32(timeout_ms);
        body.tagged_none();
        let resp = conn.request(API_DELETE_TOPICS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut out = Vec::new();
        for _ in 0..n {
            let name = r.cstr_opt().map_err(bad)?.unwrap_or_default();
            let err = r.i16().map_err(bad)? as i32;
            out.push((name, err));
        }
        Ok(out)
    }
}

pub struct ProduceOutcome {
    pub partition: i32,
    pub base_offset: i64,
    pub log_append_time_ms: i64,
    pub error_code: i32,
}

pub struct FetchOutcome {
    pub high_watermark: i64,
    /// Last stable offset (read_committed visibility bound).
    pub last_stable_offset: i64,
    /// Aborted transactions as (producer_id, first_offset).
    pub aborted: Vec<(i64, i64)>,
    pub error_code: i32,
    pub records: Vec<crate::pb::FetchedRecord>,
}

/// Build one control (transaction marker) batch. The marker
/// is never returned to consumers, but its presence in the log
/// distinguishes an aborted transaction's data batches: with
/// read_committed the broker reports them in the aborted list.
pub fn build_control_batch(
    producer_id: i64,
    producer_epoch: i16,
    commit: bool,
) -> Vec<u8> {
    // Control record: version i16(0), type i16(0=ABORT,1=COMMIT),
    // coordinator epoch i32(-1).
    let mut rec_val = W::new();
    rec_val.i16(0);
    rec_val.i16(if commit { 1 } else { 0 });
    rec_val.i32(-1);
    // Empty (null-ish) key: control batches carry no key.
    let mut rec = W::new();
    rec.i8(0); // attributes
    rec.varlong(0); // timestamp delta
    rec.varint(0); // offset delta
    // Control record key: i16 version(0) + i16 type(0=ABORT,1=COMMIT).
    let mut rec_key = W::new();
    rec_key.i16(0);
    rec_key.i16(if commit { 1 } else { 0 });
    rec.varint(rec_key.0.len() as i64);
    rec.bytes(&rec_key.0);
    rec.varint(rec_val.0.len() as i64);
    rec.bytes(&rec_val.0);
    rec.varint(0); // no headers
    let mut payload = W::new();
    payload.varint(rec.0.len() as i64);
    payload.bytes(&rec.0);
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let mut attrs: i16 = 0;
    attrs |= 1 << 5; // control flag
    attrs |= 1 << 4; // transactional flag
    let mut batch = W::new();
    batch.i64(0); // base_offset (broker assigns)
    let body_start = batch.0.len();
    batch.i32(0); // batch_length placeholder
    batch.i32(-1); // partition_leader_epoch
    batch.i8(2); // magic v2
    let crc_pos = batch.0.len();
    batch.u32(0); // crc placeholder
    batch.i16(attrs);
    batch.i32(0); // last_offset_delta
    batch.i64(now_ms);
    batch.i64(now_ms);
    batch.i64(producer_id);
    batch.i16(producer_epoch);
    batch.i32(-1); // base_sequence: none for control batches
    batch.i32(1); // record count
    batch.bytes(&payload.0);
    let batch_len = (batch.0.len() - body_start - 4) as i32;
    batch.0[body_start..body_start + 4].copy_from_slice(&batch_len.to_be_bytes());
    let crc = crc32c(&batch.0[crc_pos + 4..]);
    batch.0[crc_pos..crc_pos + 4].copy_from_slice(&crc.to_be_bytes());
    batch.0
}

/// Build one v2 record batch. `base_sequence` is -1 for
/// non-idempotent producers.
pub fn build_record_batch(
    records: &[crate::pb::Record],
    codec: u8,
    producer_id: i64,
    producer_epoch: i16,
    base_sequence: i32,
    transactional: bool,
) -> Result<Vec<u8>, String> {
    let mut payload = W::new();
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let mut base_ts: i64 = 0;
    let mut max_ts: i64 = 0;
    for (i, rec) in records.iter().enumerate() {
        let ts = if rec.timestamp_ms > 0 { rec.timestamp_ms } else { now_ms };
        if i == 0 {
            base_ts = ts;
        }
        max_ts = max_ts.max(ts);
        let mut rb = W::new();
        rb.i8(0); // attributes
        rb.varlong(ts - base_ts);
        rb.varint(i as i64);
        if rec.null_key {
            rb.varint(-1); // Kafka null key
        } else {
            // Empty-but-present key stays an empty key; only
            // null_key maps to the -1 null marker.
            rb.varint(rec.key.len() as i64);
            rb.bytes(&rec.key);
        }
        rb.varint(rec.value.len() as i64);
        rb.bytes(&rec.value);
        rb.varint(rec.headers.len() as i64);
        for h in &rec.headers {
            rb.varint(h.key.len() as i64);
            rb.bytes(h.key.as_bytes());
            rb.varint(h.value.len() as i64);
            rb.bytes(&h.value);
        }
        payload.varint(rb.0.len() as i64);
        payload.bytes(&rb.0);
    }
    let payload = codecs::compress(codec, &payload.0)?;
    let mut attrs: i16 = (codec & 0x7) as i16;
    if transactional {
        attrs |= 1 << 4;
    }
    let mut batch = W::new();
    batch.i64(0); // base_offset (relative)
    let body_start = batch.0.len();
    batch.i32(0); // batch_length placeholder
    batch.i32(-1); // partition_leader_epoch
    batch.i8(2); // magic
    let crc_pos = batch.0.len();
    batch.u32(0); // crc placeholder
    batch.i16(attrs);
    batch.i32((records.len().max(1) - 1) as i32); // last_offset_delta
    batch.i64(base_ts);
    batch.i64(max_ts);
    batch.i64(producer_id);
    batch.i16(producer_epoch);
    batch.i32(base_sequence);
    batch.i32(records.len() as i32);
    batch.bytes(&payload);
    let batch_len = (batch.0.len() - body_start - 4) as i32;
    batch.0[body_start..body_start + 4].copy_from_slice(&batch_len.to_be_bytes());
    let crc = crc32c(&batch.0[crc_pos + 4..]);
    batch.0[crc_pos..crc_pos + 4].copy_from_slice(&crc.to_be_bytes());
    Ok(batch.0)
}

impl Broker {
    #[allow(clippy::too_many_arguments)]
    pub async fn produce(
        &self,
        topic: &str,
        partition: i32,
        records: &[crate::pb::Record],
        acks: i16,
        timeout_ms: i32,
        codec: u8,
        producer_id: i64,
        producer_epoch: i16,
        base_sequence: i32,
        transactional_id: Option<&str>,
    ) -> Result<ProduceOutcome, Status> {
        let batch = build_record_batch(
            records,
            codec,
            producer_id,
            producer_epoch,
            base_sequence,
            transactional_id.is_some(),
        )
        .map_err(bad)?;
        // Route to the partition leader. On a stale-leader error
        // (5/6), refresh through the bootstrap broker, as
        // ordinary Kafka clients do after metadata changes.
        // A just-created topic can take seconds to elect
        // leaders on a loaded broker, so retry with backoff
        // instead of failing the produce.
        for attempt in 0..10 {
            let leader = self.leader_conn(topic, partition).await?;
            let outcome = self
                .produce_on(&leader, topic, partition, &batch, acks, timeout_ms, transactional_id)
                .await?;
            if !matches!(outcome.error_code, 5 | 6) || attempt == 9 {
                return Ok(outcome);
            }
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }
        unreachable!("produce retry loop returns")
    }

    #[allow(clippy::too_many_arguments)]
    async fn produce_on(
        &self,
        conn: &Arc<Mutex<Conn>>,
        topic: &str,
        partition: i32,
        batch: &[u8],
        acks: i16,
        timeout_ms: i32,
        transactional_id: Option<&str>,
    ) -> Result<ProduceOutcome, Status> {
        let mut conn = conn.lock().await;
        let (ver, flexible) = conn.pick(API_PRODUCE, 9, 7)?;
        let mut body = W::new();
        if flexible {
            body.cstr_opt(transactional_id);
            body.i16(acks);
            body.i32(timeout_ms);
            body.carr(1);
            body.cstr(topic);
            body.carr(1);
            body.i32(partition);
            body.cbytes(&batch);
            body.tagged_none(); // partition
            body.tagged_none(); // topic
            body.tagged_none(); // request
        } else {
            // Produce v7 (non-flexible), e.g. Redpanda.
            body.str16_opt(transactional_id);
            body.i16(acks);
            body.i32(timeout_ms);
            body.arr32(1);
            body.str16(topic);
            body.arr32(1);
            body.i32(partition);
            body.bytes32(&batch);
        }
        let resp = conn.request(API_PRODUCE, ver, body, flexible).await?;
        if !flexible {
            // Legacy ProduceResponse also puts throttle last.
            let mut r = R::new(&resp);
            let n = r.arr32().map_err(bad)?;
            for _ in 0..n.max(0) {
                let _name = r.str16().map_err(bad)?;
                let np = r.arr32().map_err(bad)?;
                for _ in 0..np.max(0) {
                    let part = r.i32().map_err(bad)?;
                    let err = r.i16().map_err(bad)? as i32;
                    let base = r.i64().map_err(bad)?;
                    let log_time = r.i64().map_err(bad)?;
                    let _log_start = r.i64().map_err(bad)?;
                    return Ok(ProduceOutcome { partition: part, base_offset: base, log_append_time_ms: log_time, error_code: err });
                }
            }
            return Err(bad("kafka: produce response missing partition"));
        }
        // ProduceResponse is unusual: Responses first, throttle last.
        if std::env::var("KAFKA_DEBUG").is_ok() {
            let hex: String = resp.iter().map(|b| format!("{b:02x}")).collect();
            eprintln!("produce resp ({} bytes): {hex}", resp.len());
        }
        let mut r = R::new(&resp);
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let part = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                let base = r.i64().map_err(bad)?;
                let log_time = r.i64().map_err(bad)?;
                let _log_start = r.i64().map_err(bad)?;
                let nrec_errs = r.carr_len().map_err(bad)?;
                for _ in 0..nrec_errs {
                    let _batch_index = r.i32().map_err(bad)?;
                    let _batch_msg = r.cstr_opt().map_err(bad)?;
                    r.skip_tagged().map_err(bad)?;
                }
                let _msg = r.cstr_opt().map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
                return Ok(ProduceOutcome { partition: part, base_offset: base, log_append_time_ms: log_time, error_code: err });
            }
            r.skip_tagged().map_err(bad)?;
        }
        Err(bad("kafka: produce response missing partition"))
    }

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    pub async fn fetch_on(
        &self,
        conn: &Arc<Mutex<Conn>>,
        topic: &str,
        partition: i32,
        offset: i64,
        max_wait_ms: i32,
        min_bytes: i32,
        max_bytes: i32,
        read_committed: bool,
    ) -> Result<FetchOutcome, Status> {
        let mut c = conn.lock().await;
        let ver = c.supports(API_FETCH, 12)?;
        let mut body = W::new();
        body.i32(-1); // replica_id
        body.i32(max_wait_ms);
        body.i32(min_bytes);
        body.i32(max_bytes);
        body.i8(if read_committed { 1 } else { 0 }); // isolation
        body.i32(0); // session_id
        body.i32(-1); // session_epoch
        body.carr(1);
        body.cstr(topic);
        body.carr(1);
        body.i32(partition);
        body.i32(-1); // current_leader_epoch
        body.i64(offset);
        body.i32(-1); // last_fetched_epoch
        body.i64(-1); // log_start_offset
        body.i32(max_bytes); // partition_max_bytes
        body.tagged_none();
        body.tagged_none();
        body.carr(0); // forgotten_topics
        body.cstr(""); // rack_id (non-nullable in v12)
        body.tagged_none();
        let resp = c.request(API_FETCH, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let _err = r.i16().map_err(bad)?;
        let _session = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let _part = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                let hw = r.i64().map_err(bad)?;
                let lso = r.i64().map_err(bad)?;
                let _log_start = r.i64().map_err(bad)?;
                // v12: no diverging-epoch/current-leader/snapshot
                // fields (those arrive in later versions).
                let mut aborted: Vec<(i64, i64)> = Vec::new();
                if let Some(count) = r.carr().map_err(bad)? {
                    for _ in 0..count {
                        let pid = r.i64().map_err(bad)?;
                        let first = r.i64().map_err(bad)?;
                        r.skip_tagged().map_err(bad)?;
                        aborted.push((pid, first));
                    }
                }
                let _preferred = r.i32().map_err(bad)?;
                let records_bytes = r.cbytes_opt().map_err(bad)?.unwrap_or_default();
                r.skip_tagged().map_err(bad)?;
                let mut records = if err == 0 && !records_bytes.is_empty() {
                    parse_record_batches_tagged(&records_bytes).map_err(bad)?
                } else {
                    Vec::new()
                };
                if read_committed {
                    // Belt-and-braces isolation: some brokers
                    // return open/aborted transactional batches
                    // under read_committed without listing them
                    // as aborted. Drop anything at/after the last
                    // stable offset and anything from an aborted
                    // producer (tagged at parse time). Control
                    // records themselves are filtered separately
                    // below, on both paths.
                    records.retain(|rec| {
                        rec.offset < lso
                            && !aborted.iter().any(|(pid, first)| {
                                rec.producer_id == *pid && rec.offset >= *first
                            })
                    });
                }
                // Control batches are transaction markers, never
                // user data, under either isolation level.
                records.retain(|rec| !rec.control);
                let records: Vec<crate::pb::FetchedRecord> =
                    records.into_iter().map(|t| t.record).collect();
                return Ok(FetchOutcome {
                    high_watermark: hw,
                    last_stable_offset: lso,
                    aborted,
                    error_code: err,
                    records,
                });
            }
            r.skip_tagged().map_err(bad)?;
        }
        Err(bad("kafka: fetch response missing partition"))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn fetch(
        &self,
        topic: &str,
        partition: i32,
        offset: i64,
        max_wait_ms: i32,
        min_bytes: i32,
        max_bytes: i32,
        read_committed: bool,
    ) -> Result<FetchOutcome, Status> {
        let conn = self.leader_conn(topic, partition).await?;
        match self
            .fetch_on(
                &conn,
                topic,
                partition,
                offset,
                max_wait_ms,
                min_bytes,
                max_bytes,
                read_committed,
            )
            .await
        {
            Ok(outcome) if matches!(outcome.error_code, 5 | 6) => {
                let boot = self.bootstrap().await?;
                self.fetch_on(
                    &boot,
                    topic,
                    partition,
                    offset,
                    max_wait_ms,
                    min_bytes,
                    max_bytes,
                    read_committed,
                )
                .await
            }
            other => other,
        }
    }

    pub async fn list_offsets(
        &self,
        topic: &str,
        partition: i32,
        timestamp: i64,
        read_committed: bool,
    ) -> Result<(i64, i64, i32), Status> {
        let boot = self.leader_conn(topic, partition).await?;
        let mut conn = boot.lock().await;
        let ver = conn.supports(API_LIST_OFFSETS, 6)?;
        let mut body = W::new();
        body.i32(-1); // replica_id
        body.i8(if read_committed { 1 } else { 0 }); // isolation
        body.carr(1);
        body.cstr(topic);
        body.carr(1);
        body.i32(partition);
        body.i32(-1); // current_leader_epoch
        body.i64(timestamp);
        body.tagged_none();
        body.tagged_none();
        body.tagged_none();
        let resp = conn.request(API_LIST_OFFSETS, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let _p = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                let ts = r.i64().map_err(bad)?;
                let off = r.i64().map_err(bad)?;
                r.skip_tagged().map_err(bad)?;
                return Ok((off, ts, err));
            }
            r.skip_tagged().map_err(bad)?;
        }
        Err(bad("kafka: list_offsets response missing partition"))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn offset_commit(
        &self,
        group: &str,
        generation_id: i32,
        member_id: &str,
        group_instance_id: Option<&str>,
        topic: &str,
        partition: i32,
        offset: i64,
        metadata: &str,
    ) -> Result<i32, Status> {
        // Retry through coordinator rediscovery on transient
        // coordinator errors (14 COORDINATOR_LOAD_IN_PROGRESS,
        // 15 COORDINATOR_NOT_AVAILABLE, 16 NOT_COORDINATOR):
        // on a fresh group Redpanda answers 16 until its
        // coordinator finishes loading.
        for attempt in 0..12 {
            match self.offset_commit_once(
                group,
                generation_id,
                member_id,
                group_instance_id,
                topic,
                partition,
                offset,
                metadata,
            )
            .await
            {
                Ok(code) => {
                    if matches!(code, 14 | 15 | 16) && attempt < 11 {
                        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                        continue;
                    }
                    return Ok(code);
                }
                Err(status) => {
                    if attempt < 11 {
                        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                        continue;
                    }
                    return Err(status);
                }
            }
        }
        Err(bad("kafka: offset_commit retries exhausted"))
    }

    #[allow(clippy::too_many_arguments)]
    async fn offset_commit_once(
        &self,
        group: &str,
        generation_id: i32,
        member_id: &str,
        group_instance_id: Option<&str>,
        topic: &str,
        partition: i32,
        offset: i64,
        metadata: &str,
    ) -> Result<i32, Status> {
        let coord = self.coordinator(group, 0).await?;
        let mut conn = coord.lock().await;
        // v9 has the v8 wire layout; KIP-848 consumer groups
        // reject commits below v9 with UNSUPPORTED_VERSION, so
        // negotiate up to it (classic brokers keep v8).
        let ver = conn.negotiate(API_OFFSET_COMMIT, 9)?;
        let mut body = W::new();
        body.cstr(group);
        body.i32(generation_id);
        body.cstr(member_id);
        body.cstr_opt(group_instance_id);
        // v8: retention_time_ms no longer exists.
        body.carr(1);
        body.cstr(topic);
        body.carr(1);
        body.i32(partition);
        body.i64(offset);
        body.i32(-1); // committed_leader_epoch
        body.cstr_opt(Some(metadata));
        body.tagged_none();
        body.tagged_none();
        body.tagged_none();
        let resp = conn.request(API_OFFSET_COMMIT, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let _p = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                r.skip_tagged().map_err(bad)?;
                return Ok(err);
            }
            r.skip_tagged().map_err(bad)?;
        }
        Err(bad("kafka: offset_commit response missing partition"))
    }

    pub async fn offset_fetch(&self, group: &str, topic: &str, partition: i32) -> Result<(i64, String, i32), Status> {
        let coord = self.coordinator(group, 0).await?;
        let mut conn = coord.lock().await;
        let ver = conn.supports(API_OFFSET_FETCH, 6)?;
        let mut body = W::new();
        body.cstr(group);
        body.carr(1);
        body.cstr(topic);
        body.carr(1);
        body.i32(partition);
        body.tagged_none();
        body.tagged_none();
        body.tagged_none();
        let resp = conn.request(API_OFFSET_FETCH, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let _p = r.i32().map_err(bad)?;
                let off = r.i64().map_err(bad)?;
                let _epoch = r.i32().map_err(bad)?;
                let meta = r.cstr_opt().map_err(bad)?.unwrap_or_default();
                let err = r.i16().map_err(bad)? as i32;
                r.skip_tagged().map_err(bad)?;
                return Ok((off, meta, err));
            }
            r.skip_tagged().map_err(bad)?;
        }
        let err = r.i16().map_err(bad)? as i32;
        Ok((-1, String::new(), err))
    }
}

/// Parse record batches out of a Fetch response payload.
/// A fetched record plus the batch-level provenance needed
/// for read_committed filtering (not part of the wire proto).
pub struct TaggedRecord {
    pub record: crate::pb::FetchedRecord,
    /// Offset of this record in the partition log.
    pub offset: i64,
    /// Producer id of the batch (-1 for plain producers).
    pub producer_id: i64,
    /// Records from control (marker) batches; never data.
    pub control: bool,
    /// Batch carried the transactional flag.
    pub transactional: bool,
}

pub fn parse_record_batches(data: &[u8]) -> Result<Vec<crate::pb::FetchedRecord>, String> {
    Ok(parse_record_batches_tagged(data)?
        .into_iter()
        .filter(|t| !t.control)
        .map(|t| t.record)
        .collect())
}

pub fn parse_record_batches_tagged(data: &[u8]) -> Result<Vec<TaggedRecord>, String> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos + 61 <= data.len() {
        let mut r = R::new(&data[pos..]);
        let base_offset = r.i64()?;
        let batch_len = r.i32()? as usize;
        let _epoch = r.i32()?;
        let magic = r.i8()?;
        if magic != 2 {
            break;
        }
        let _crc = r.u32()?;
        let attrs = r.i16()?;
        let _last_delta = r.i32()?;
        let base_ts = r.i64()?;
        let _max_ts = r.i64()?;
        let batch_pid = r.i64()?;
        let _pepoch = r.i16()?;
        let _seq = r.i32()?;
        let count = r.i32()?;
        let header_len = 61usize;
        let total = 8 + 4 + batch_len;
        if pos + total > data.len() {
            break;
        }
        let records_end = pos + total;
        let payload_start = pos + header_len;
        let codec = (attrs & 0x7) as u8;
        let control = attrs & (1 << 5) != 0;
        let raw = &data[payload_start..records_end];
        let payload;
        let payload_ref: &[u8] = if codec != 0 {
            payload = codecs::decompress(codec, raw)?;
            &payload
        } else {
            raw
        };
        {
            let mut rr = R::new(payload_ref);
            for _ in 0..count {
                let _len = rr.varint()?;
                let _attr = rr.i8()?;
                let ts_delta = rr.varint()?;
                let off_delta = rr.varint()?;
                let klen = rr.varint()?;
                let key_null = klen < 0;
                let key = if key_null { Vec::new() } else { rr.take(klen as usize)?.to_vec() };
                let vlen = rr.varint()?;
                let value = if vlen < 0 { Vec::new() } else { rr.take(vlen as usize)?.to_vec() };
                let nh = rr.varint()?;
                let mut headers = Vec::new();
                for _ in 0..nh.max(0) {
                    let hklen = rr.varint()?;
                    let hk = if hklen < 0 { Vec::new() } else { rr.take(hklen as usize)?.to_vec() };
                    let hvlen = rr.varint()?;
                    let hv = if hvlen < 0 { Vec::new() } else { rr.take(hvlen as usize)?.to_vec() };
                    headers.push(crate::pb::Header {
                        key: String::from_utf8_lossy(&hk).into_owned(),
                        value: hv,
                        ..Default::default()
                    });
                }
                out.push(TaggedRecord {
                    offset: base_offset + off_delta,
                    producer_id: batch_pid,
                    control,
                    transactional: attrs & (1 << 4) != 0,
                    record: crate::pb::FetchedRecord {
                        offset: base_offset + off_delta,
                        timestamp_ms: base_ts + ts_delta,
                        key,
                        key_null,
                        value,
                        headers,
                        ..Default::default()
                    },
                });
            }
        }
        pos += total;
        let _ = r;
    }
    Ok(out)
}

pub struct JoinOutcome {
    pub error_code: i32,
    pub generation_id: i32,
    pub member_id: String,
    pub leader_id: String,
    pub protocol_name: String,
    /// (member_id, group_instance_id, subscription bytes)
    pub members: Vec<(String, Option<String>, Vec<u8>)>,
}

impl Broker {
    pub async fn init_producer_id(
        &self,
        transactional_id: Option<&str>,
        transaction_timeout_ms: i32,
    ) -> Result<(i64, i16, i32), Status> {
        // Retry while the transaction coordinator loads or moves
        // (14/15, plus NOT_COORDINATOR 16): rediscover it each
        // attempt, matching ordinary Kafka client behavior.
        let mut last = (0i64, 0i16, 0i32);
        for attempt in 0..20 {
            let conn = match transactional_id {
                Some(tid) => self.coordinator(tid, 1).await?,
                None => self.bootstrap().await?,
            };
            let mut c = conn.lock().await;
            // InitProducerId is flexible from v3; v4 adds the
            // producer id/epoch fields for epoch bumps.
            let max = c
                .versions
                .get(&API_INIT_PRODUCER_ID)
                .map(|&(_, mx)| mx)
                .ok_or_else(|| bad("kafka: InitProducerId not advertised"))?;
            if max < 3 {
                return Err(bad(format!(
                    "kafka: InitProducerId version too old (broker max {max})"
                )));
            }
            let ver = max.min(4);
            let flexible = true;
            let mut body = W::new();
            body.cstr_opt(transactional_id);
            body.i32(transaction_timeout_ms);
            // v4 fields; Redpanda (max v3) expects them at v3 too.
            body.i64(-1); // producer_id (new)
            body.i16(-1); // producer_epoch
            body.tagged_none();
            let resp = c.request(API_INIT_PRODUCER_ID, ver, body.clone(), flexible).await?;
            let mut r = R::new(&resp);
            let _throttle = r.i32().map_err(bad)?;
            let err = r.i16().map_err(bad)? as i32;
            let pid = r.i64().map_err(bad)?;
            let epoch = r.i16().map_err(bad)?;
            last = (pid, epoch, err);
            if !matches!(err, 14 | 15 | 16) || attempt == 19 {
                break;
            }
            drop(c);
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        }
        Ok(last)
    }

    pub async fn add_partitions_to_txn(
        &self,
        transactional_id: &str,
        producer_id: i64,
        producer_epoch: i16,
        topics: Vec<(String, Vec<i32>)>,
    ) -> Result<Vec<(String, i32, i32)>, Status> {
        let conn = self.coordinator(transactional_id, 1).await?;
        let mut c = conn.lock().await;
        let ver = c.supports(API_ADD_PARTITIONS_TO_TXN, 3)?;
        // v3 is the flat layout (per-transaction list is v4+).
        let mut body = W::new();
        body.cstr(transactional_id);
        body.i64(producer_id);
        body.i16(producer_epoch);
        body.carr(topics.len());
        for (name, parts) in &topics {
            body.cstr(name);
            body.carr(parts.len());
            for p in parts {
                body.i32(*p);
            }
            body.tagged_none();
        }
        body.tagged_none();
        let resp = c.request(API_ADD_PARTITIONS_TO_TXN, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut out = Vec::new();
        for _ in 0..n {
            let name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let part = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                r.skip_tagged().map_err(bad)?;
                out.push((name.clone(), part, err));
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok(out)
    }

    pub async fn add_offsets_to_txn(
        &self,
        transactional_id: &str,
        group_id: &str,
        producer_id: i64,
        producer_epoch: i16,
    ) -> Result<i32, Status> {
        let conn = self.coordinator(transactional_id, 1).await?;
        let mut c = conn.lock().await;
        let (ver, flexible) = c.pick(API_ADD_OFFSETS_TO_TXN, 3, 1)?;
        let mut body = W::new();
        if flexible {
            body.cstr(transactional_id);
            body.i64(producer_id);
            body.i16(producer_epoch);
            body.cstr(group_id);
            body.tagged_none();
        } else {
            // v1 (non-flexible), e.g. Redpanda.
            body.str16(transactional_id);
            body.i64(producer_id);
            body.i16(producer_epoch);
            body.str16(group_id);
        }
        let resp = c.request(API_ADD_OFFSETS_TO_TXN, ver, body, flexible).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        Ok(r.i16().map_err(bad)? as i32)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn txn_offset_commit(
        &self,
        transactional_id: &str,
        group_id: &str,
        producer_id: i64,
        producer_epoch: i16,
        topic: &str,
        partition: i32,
        offset: i64,
        metadata: &str,
    ) -> Result<i32, Status> {
        let conn = self.coordinator(group_id, 0).await?;
        let mut c = conn.lock().await;
        let ver = c.supports(API_TXN_OFFSET_COMMIT, 3)?;
        let mut body = W::new();
        body.cstr(transactional_id);
        body.cstr(group_id);
        body.i64(producer_id);
        body.i16(producer_epoch);
        // v3 (KIP-447, first flexible version): generation_id,
        // member_id, group_instance_id precede topics. Defaults
        // (-1, "", null) tell the broker to skip zombie fencing.
        body.i32(-1);
        body.cstr("");
        body.cstr_opt(None);
        body.carr(1);
        body.cstr(topic);
        body.carr(1);
        body.i32(partition);
        body.i64(offset);
        body.i32(-1); // leader epoch
        body.cstr_opt(Some(metadata));
        body.tagged_none();
        body.tagged_none();
        body.tagged_none();
        let resp = c.request(API_TXN_OFFSET_COMMIT, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        for _ in 0..n {
            let _name = r.cstr().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let _p = r.i32().map_err(bad)?;
                let err = r.i16().map_err(bad)? as i32;
                r.skip_tagged().map_err(bad)?;
                return Ok(err);
            }
            r.skip_tagged().map_err(bad)?;
        }
        Err(bad("kafka: txn_offset_commit response missing partition"))
    }

    /// Write an ABORT/COMMIT control batch to each partition the
    /// transaction touched. Brokers normally append these markers
    /// themselves when EndTxn completes; Redpanda opens the txn
    /// without markers, so the proxy appends them (idempotent on
    /// Kafka: a duplicate abort marker hits the aborted list and
    /// stays invisible either way) so read_committed hides
    /// aborted data on both brokers.
    pub async fn write_txn_markers(
        &self,
        partitions: &[(String, i32)],
        producer_id: i64,
        producer_epoch: i16,
        commit: bool,
        transactional_id: &str,
    ) -> Result<(), Status> {
        let batch = build_control_batch(producer_id, producer_epoch, commit);
        for (topic, partition) in partitions {
            let conn = self.leader_conn(topic, *partition).await?;
            let outcome = self
                .produce_on(&conn, topic, *partition, &batch, -1, 30_000, Some(transactional_id))
                .await?;
            if outcome.error_code != 0 {
                eprintln!(
                    "kafka: txn marker write to {topic}:{partition} returned {}",
                    outcome.error_code
                );
            }
        }
        Ok(())
    }

    pub async fn end_txn(
        &self,
        transactional_id: &str,
        producer_id: i64,
        producer_epoch: i16,
        commit: bool,
    ) -> Result<i32, Status> {
        let conn = self.coordinator(transactional_id, 1).await?;
        let mut c = conn.lock().await;
        let ver = c.supports(API_END_TXN, 3)?;
        let mut body = W::new();
        body.cstr(transactional_id);
        body.i64(producer_id);
        body.i16(producer_epoch);
        body.i8(commit as i8);
        body.tagged_none();
        let resp = c.request(API_END_TXN, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        Ok(r.i16().map_err(bad)? as i32)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn join_group(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        member_id: &str,
        group_instance_id: Option<&str>,
        session_timeout_ms: i32,
        rebalance_timeout_ms: i32,
        protocols: Vec<(String, Vec<u8>)>,
    ) -> Result<JoinOutcome, Status> {
        let mut c = conn.lock().await;
        let ver = c.supports(API_JOIN_GROUP, 6)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.i32(session_timeout_ms);
        body.i32(rebalance_timeout_ms);
        body.cstr(member_id);
        body.cstr_opt(group_instance_id);
        body.cstr("consumer");
        body.carr(protocols.len());
        for (name, meta) in &protocols {
            body.cstr(name);
            body.cbytes(meta);
            body.tagged_none();
        }
        body.tagged_none();
        let resp = c.request(API_JOIN_GROUP, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let err = r.i16().map_err(bad)? as i32;
        let generation = r.i32().map_err(bad)?;
        // v6 response: no protocol_type, no skip_assignment.
        let protocol_name = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let leader = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let member = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let nm = r.carr_len().map_err(bad)?;
        let mut members = Vec::new();
        for _ in 0..nm {
            let mid = r.cstr().map_err(bad)?;
            let inst = r.cstr_opt().map_err(bad)?;
            let meta = r.cbytes().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
            members.push((mid, inst, meta));
        }
        Ok(JoinOutcome {
            error_code: err,
            generation_id: generation,
            member_id: member,
            leader_id: leader,
            protocol_name,
            members,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn sync_group(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        generation_id: i32,
        member_id: &str,
        group_instance_id: Option<&str>,
        protocol_name: &str,
        assignments: Vec<(String, Vec<u8>)>,
    ) -> Result<(i32, Vec<u8>), Status> {
        let mut c = conn.lock().await;
        let ver = c.supports(API_SYNC_GROUP, 4)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.i32(generation_id);
        body.cstr(member_id);
        body.cstr_opt(group_instance_id);
        // v4 request: no protocol_type/protocol_name (v5+).
        let _ = protocol_name;
        body.carr(assignments.len());
        for (member, bytes) in &assignments {
            body.cstr(member);
            body.cbytes(bytes);
            body.tagged_none();
        }
        body.tagged_none();
        let resp = c.request(API_SYNC_GROUP, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let err = r.i16().map_err(bad)? as i32;
        // v4 response: no protocol_type/protocol_name (v5+).
        let assignment = r.cbytes().map_err(bad)?;
        Ok((err, assignment))
    }

    pub async fn heartbeat(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        generation_id: i32,
        member_id: &str,
        group_instance_id: Option<&str>,
    ) -> Result<i32, Status> {
        let mut c = conn.lock().await;
        let ver = c.supports(API_HEARTBEAT, 4)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.i32(generation_id);
        body.cstr(member_id);
        body.cstr_opt(group_instance_id);
        body.tagged_none();
        let resp = c.request(API_HEARTBEAT, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        Ok(r.i16().map_err(bad)? as i32)
    }

    pub async fn leave_group(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        member_id: &str,
        group_instance_id: Option<&str>,
    ) -> Result<i32, Status> {
        let mut c = conn.lock().await;
        let ver = c.supports(API_LEAVE_GROUP, 4)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.carr(1);
        body.cstr(member_id);
        body.cstr_opt(group_instance_id);
        body.cstr_opt(None); // reason
        body.tagged_none();
        body.tagged_none();
        let resp = c.request(API_LEAVE_GROUP, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        Ok(r.i16().map_err(bad)? as i32)
    }

    /// Topic name <-> id (UUID) maps from Metadata at v10+
    /// (KIP-516 topic ids). Empty maps when the broker's
    /// Metadata max version predates topic ids.
    pub async fn topic_id_maps(
        &self,
        topics: &[String],
    ) -> Result<
        (
            std::collections::HashMap<String, [u8; 16]>,
            std::collections::HashMap<[u8; 16], String>,
        ),
        Status,
    > {
        let boot = self.bootstrap().await?;
        let mut conn = boot.lock().await;
        let ver = conn.negotiate(API_METADATA, 12)?;
        let mut by_name = std::collections::HashMap::new();
        let mut by_id = std::collections::HashMap::new();
        if ver < 10 {
            return Ok((by_name, by_id));
        }
        let mut body = W::new();
        if topics.is_empty() {
            body.uvarint(0);
        } else {
            body.carr(topics.len());
            for t in topics {
                body.bytes(&[0u8; 16]); // topic id: zero = by name
                body.cstr_opt(Some(t));
                body.tagged_none();
            }
        }
        body.i8(0); // allow_auto_topic_creation
        body.i8(0); // include_cluster_authorized_operations
        body.i8(0); // include_topic_authorized_operations
        body.tagged_none();
        let resp = conn.request(API_METADATA, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let nb = r.carr_len().map_err(bad)?;
        for _ in 0..nb {
            let _node = r.i32().map_err(bad)?;
            let _host = r.cstr().map_err(bad)?;
            let _port = r.i32().map_err(bad)?;
            let _rack = r.cstr_opt().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        let _cluster = r.cstr_opt().map_err(bad)?;
        let _controller = r.i32().map_err(bad)?;
        let nt = r.carr_len().map_err(bad)?;
        for _ in 0..nt {
            let _err = r.i16().map_err(bad)?;
            let name = r.cstr_opt().map_err(bad)?.unwrap_or_default();
            let id_bytes = r.take(16).map_err(bad)?;
            let mut id = [0u8; 16];
            id.copy_from_slice(id_bytes);
            let _internal = r.i8().map_err(bad)?;
            let np = r.carr_len().map_err(bad)?;
            for _ in 0..np {
                let _perr = r.i16().map_err(bad)?;
                let _pid = r.i32().map_err(bad)?;
                let _leader = r.i32().map_err(bad)?;
                let _epoch = r.i32().map_err(bad)?;
                let nr = r.carr_len().map_err(bad)?;
                for _ in 0..nr {
                    let _ = r.i32().map_err(bad)?;
                }
                let ni = r.carr_len().map_err(bad)?;
                for _ in 0..ni {
                    let _ = r.i32().map_err(bad)?;
                }
                let no = r.carr_len().map_err(bad)?;
                for _ in 0..no {
                    let _ = r.i32().map_err(bad)?;
                }
                r.skip_tagged().map_err(bad)?;
            }
            let _ops = r.i32().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
            if !name.is_empty() && id != [0u8; 16] {
                by_name.insert(name.clone(), id);
                by_id.insert(id, name);
            }
        }
        Ok((by_name, by_id))
    }

    /// KIP-848 ConsumerGroupHeartbeat (API 68): one heartbeat
    /// round. member_epoch 0 joins, -1 leaves, otherwise the
    /// epoch from the previous response. `current` acknowledges
    /// the assignment the member currently holds (topic id ->
    /// partitions); the response assignment replaces it when
    /// present.
    #[allow(clippy::too_many_arguments)]
    pub async fn consumer_heartbeat(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        member_id: &str,
        member_epoch: i32,
        group_instance_id: Option<&str>,
        rebalance_timeout_ms: i32,
        subscribed_topics: &[String],
        current: &[([u8; 16], Vec<i32>)],
    ) -> Result<ConsumerHeartbeat, Status> {
        let mut c = conn.lock().await;
        let ver = c.negotiate(API_CONSUMER_GROUP_HEARTBEAT, 0)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.cstr(member_id);
        body.i32(member_epoch);
        body.cstr_opt(group_instance_id);
        body.cstr_opt(None); // rack_id
        body.i32(rebalance_timeout_ms);
        body.carr(subscribed_topics.len());
        for t in subscribed_topics {
            body.cstr(t);
        }
        // SubscribedTopicRegex only exists at v1+; at v0 the
        // ServerAssignor follows SubscribedTopicNames directly.
        if ver >= 1 {
            body.cstr_opt(None); // subscribed_topic_regex
        }
        body.cstr_opt(None); // server_assignor: broker default
        body.carr(current.len());
        for (id, partitions) in current {
            body.bytes(id);
            body.carr(partitions.len());
            for p in partitions {
                body.i32(*p);
            }
            body.tagged_none();
        }
        body.tagged_none();
        let resp = c
            .request(API_CONSUMER_GROUP_HEARTBEAT, ver, body, true)
            .await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        let error_message = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let member = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let epoch = r.i32().map_err(bad)?;
        let interval = r.i32().map_err(bad)?;
        // Assignment is a nullable struct: a signed presence
        // byte (0xff = null, 0x01 = present) precedes the
        // TopicPartitions array. Null = unchanged; a present
        // (possibly empty) assignment replaces what the member
        // holds.
        let mut assignment = None;
        let present = r.i8().map_err(bad)?;
        if present > 0 {
            let n = r.carr_len().map_err(bad)?;
            let mut entries = Vec::new();
            for _ in 0..n {
                let id_bytes = r.take(16).map_err(bad)?;
                let mut id = [0u8; 16];
                id.copy_from_slice(id_bytes);
                let np = r.carr_len().map_err(bad)?;
                let mut partitions = Vec::new();
                for _ in 0..np {
                    partitions.push(r.i32().map_err(bad)?);
                }
                r.skip_tagged().map_err(bad)?;
                entries.push((id, partitions));
            }
            assignment = Some(entries);
            r.skip_tagged().map_err(bad)?; // Assignment struct
        }
        r.skip_tagged().map_err(bad)?;
        Ok(ConsumerHeartbeat {
            error_code,
            error_message,
            member_id: member,
            member_epoch: epoch,
            heartbeat_interval_ms: interval,
            assignment,
        })
    }

    /// KIP-848 ConsumerGroupDescribe (API 69) for one group,
    /// mapped onto the classic DescribedGroup shape
    /// (protocol_type "consumer"). Used when classic
    /// DescribeGroups reports GROUP_ID_NOT_FOUND for a group
    /// that lives under the next-gen protocol.
    pub async fn describe_consumer_group(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
    ) -> Result<crate::pb::DescribedGroup, Status> {
        let mut c = conn.lock().await;
        let ver = c.negotiate(API_CONSUMER_GROUP_DESCRIBE, 0)?;
        let mut body = W::new();
        body.carr(1);
        body.cstr(group_id);
        body.i8(0); // include_authorized_operations
        body.tagged_none();
        let resp = c
            .request(API_CONSUMER_GROUP_DESCRIBE, ver, body, true)
            .await?;
        drop(c);
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut described = crate::pb::DescribedGroup {
            group_id: group_id.to_string(),
            error_code: 69,
            protocol_type: "consumer".to_string(),
            ..Default::default()
        };
        // Topic ids encountered in assignments resolve through
        // one Metadata round, made after this response parses.
        let mut pending: Vec<(String, String, String, Vec<([u8; 16], String, Vec<i32>)>)> =
            Vec::new();
        for _ in 0..n {
            described.error_code = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            described.group_id = r.cstr().map_err(bad)?;
            described.group_state = r.cstr().map_err(bad)?;
            let _group_epoch = r.i32().map_err(bad)?;
            let _assignment_epoch = r.i32().map_err(bad)?;
            let _assignor = r.cstr().map_err(bad)?;
            let nmembers = r.carr_len().map_err(bad)?;
            for _ in 0..nmembers {
                let member_id = r.cstr().map_err(bad)?;
                let _instance = r.cstr_opt().map_err(bad)?;
                let _rack = r.cstr_opt().map_err(bad)?;
                let _epoch = r.i32().map_err(bad)?;
                let client_id = r.cstr().map_err(bad)?;
                let client_host = r.cstr().map_err(bad)?;
                let nsub = r.carr_len().map_err(bad)?;
                for _ in 0..nsub {
                    let _ = r.cstr().map_err(bad)?;
                }
                let _regex = r.cstr_opt().map_err(bad)?;
                let assignment = read_describe_assignment(&mut r)?;
                let _target = read_describe_assignment(&mut r)?;
                r.skip_tagged().map_err(bad)?;
                pending.push((member_id, client_id, client_host, assignment));
            }
            let _authorized = r.i32().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        let names: Vec<String> = pending
            .iter()
            .flat_map(|(_, _, _, a)| a.iter().map(|(_, name, _)| name.clone()))
            .filter(|name| !name.is_empty())
            .collect();
        let (by_name, by_id) = if names.iter().all(|name| !name.is_empty())
            && pending
                .iter()
                .all(|(_, _, _, a)| a.iter().all(|(_, name, _)| !name.is_empty()))
        {
            (Default::default(), Default::default())
        } else {
            self.topic_id_maps(&[]).await.unwrap_or_default()
        };
        let _ = by_name;
        for (member_id, client_id, client_host, assignment) in pending {
            described.members.push(crate::pb::GroupMember {
                member_id,
                client_id,
                client_host,
                assignment: assignment
                    .into_iter()
                    .flat_map(|(id, name, partitions)| {
                        let topic = if !name.is_empty() {
                            name
                        } else {
                            by_id.get(&id).cloned().unwrap_or_default()
                        };
                        partitions
                            .into_iter()
                            .map(move |partition| crate::pb::TopicPartition {
                                topic: topic.clone(),
                                partition,
                                ..Default::default()
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect(),
                ..Default::default()
            });
        }
        Ok(described)
    }

    /// KIP-932 ShareGroupDescribe (API 77) for one group.
    pub async fn share_group_describe(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
    ) -> Result<crate::pb::ShareGroupDescription, Status> {
        let mut c = conn.lock().await;
        let ver = c.negotiate(API_SHARE_GROUP_DESCRIBE, 1)?;
        let mut body = W::new();
        body.carr(1);
        body.cstr(group_id);
        body.i8(0); // include_authorized_operations
        body.tagged_none();
        let resp = c
            .request(API_SHARE_GROUP_DESCRIBE, ver, body, true)
            .await?;
        drop(c);
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let n = r.carr_len().map_err(bad)?;
        let mut described = crate::pb::ShareGroupDescription {
            group_id: group_id.to_string(),
            ..Default::default()
        };
        // (member_id, epoch, client_id, client_host, topics, assignment)
        let mut pending: Vec<(
            String,
            i32,
            String,
            String,
            Vec<String>,
            Vec<([u8; 16], String, Vec<i32>)>,
        )> = Vec::new();
        for _ in 0..n {
            described.error_code = r.i16().map_err(bad)? as i32;
            let _msg = r.cstr_opt().map_err(bad)?;
            described.group_id = r.cstr().map_err(bad)?;
            described.state = r.cstr().map_err(bad)?;
            described.group_epoch = r.i32().map_err(bad)?;
            described.assignment_epoch = r.i32().map_err(bad)?;
            let _assignor = r.cstr().map_err(bad)?;
            let nmembers = r.carr_len().map_err(bad)?;
            for _ in 0..nmembers {
                let member_id = r.cstr().map_err(bad)?;
                let _rack = r.cstr_opt().map_err(bad)?;
                let member_epoch = r.i32().map_err(bad)?;
                let client_id = r.cstr().map_err(bad)?;
                let client_host = r.cstr().map_err(bad)?;
                let nsub = r.carr_len().map_err(bad)?;
                let mut subscribed = Vec::new();
                for _ in 0..nsub {
                    subscribed.push(r.cstr().map_err(bad)?);
                }
                let assignment = read_describe_assignment(&mut r)?;
                r.skip_tagged().map_err(bad)?;
                pending.push((
                    member_id,
                    member_epoch,
                    client_id,
                    client_host,
                    subscribed,
                    assignment,
                ));
            }
            let _authorized = r.i32().map_err(bad)?;
            r.skip_tagged().map_err(bad)?;
        }
        let needs_names = pending
            .iter()
            .any(|(_, _, _, _, _, a)| a.iter().any(|(_, name, _)| name.is_empty()));
        let (_by_name, by_id) = if needs_names {
            self.topic_id_maps(&[]).await.unwrap_or_default()
        } else {
            (Default::default(), Default::default())
        };
        for (member_id, member_epoch, client_id, client_host, subscribed, assignment) in pending
        {
            described.members.push(crate::pb::ShareGroupMember {
                member_id,
                member_epoch,
                client_id,
                client_host,
                subscribed_topics: subscribed,
                assignment: assignment
                    .into_iter()
                    .flat_map(|(id, name, partitions)| {
                        let topic = if !name.is_empty() {
                            name
                        } else {
                            by_id.get(&id).cloned().unwrap_or_default()
                        };
                        partitions
                            .into_iter()
                            .map(move |partition| crate::pb::TopicPartition {
                                topic: topic.clone(),
                                partition,
                                ..Default::default()
                            })
                            .collect::<Vec<_>>()
                    })
                    .collect(),
                ..Default::default()
            });
        }
        Ok(described)
    }

    /// KIP-932 ShareGroupHeartbeat (API 76): join/maintain a
    /// share group member. member_epoch 0 joins, -1 leaves.
    /// Response mirrors ConsumerGroupHeartbeat, except the
    /// assignment TopicPartitions carry no topic name.
    /// Unlike KIP-848, the member id is client-generated: an
    /// empty `member_id` on a join (epoch 0) mints one. Pass
    /// `subscribed_topics: None` on maintenance heartbeats
    /// (subscription unchanged), like the reference client.
    #[allow(clippy::too_many_arguments)]
    pub async fn share_heartbeat(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        member_id: &str,
        member_epoch: i32,
        group_instance_id: Option<&str>,
        subscribed_topics: Option<&[String]>,
    ) -> Result<ConsumerHeartbeat, Status> {
        let _ = group_instance_id;
        let mut c = conn.lock().await;
        let ver = c.negotiate(API_SHARE_GROUP_HEARTBEAT, 1)?;
        let generated;
        let member_id = if member_id.is_empty() && member_epoch == 0 {
            generated = make_share_member_id();
            generated.as_str()
        } else {
            member_id
        };
        let mut body = W::new();
        body.cstr(group_id);
        body.cstr(member_id);
        body.i32(member_epoch);
        body.cstr_opt(None); // rack_id
        match subscribed_topics {
            Some(topics) => {
                body.carr(topics.len());
                for t in topics {
                    body.cstr(t);
                }
            }
            None => body.uvarint(0), // null: subscription unchanged
        }
        body.tagged_none();
        let resp = c.request(API_SHARE_GROUP_HEARTBEAT, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        let error_message = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let member = r.cstr_opt().map_err(bad)?.unwrap_or_default();
        let epoch = r.i32().map_err(bad)?;
        let interval = r.i32().map_err(bad)?;
        let mut assignment = None;
        // Assignment is v1+; at v0 the body ends here.
        if ver >= 1 {
            let present = r.i8().map_err(bad)?;
            if present > 0 {
                let n = r.carr_len().map_err(bad)?;
                let mut entries = Vec::new();
                for _ in 0..n {
                    let id_bytes = r.take(16).map_err(bad)?;
                    let mut id = [0u8; 16];
                    id.copy_from_slice(id_bytes);
                    let np = r.carr_len().map_err(bad)?;
                    let mut partitions = Vec::new();
                    for _ in 0..np {
                        partitions.push(r.i32().map_err(bad)?);
                    }
                    r.skip_tagged().map_err(bad)?;
                    entries.push((id, partitions));
                }
                assignment = Some(entries);
                r.skip_tagged().map_err(bad)?;
            }
        }
        Ok(ConsumerHeartbeat {
            error_code,
            error_message,
            member_id: member,
            member_epoch: epoch,
            heartbeat_interval_ms: interval,
            assignment,
        })
    }

    /// KIP-932 ShareFetch (API 78): acquire records from the
    /// assigned share partitions. `topics` is the member's
    /// current assignment as (topic id, partitions); ack
    /// batches piggyback on the fetch (may be empty).
    #[allow(clippy::too_many_arguments)]
    pub async fn share_fetch(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        member_id: &str,
        session_epoch: i32,
        max_wait_ms: i32,
        max_records: i32,
        topics: &[([u8; 16], Vec<i32>)],
        acks: &[([u8; 16], i32, Vec<ShareAckBatch>)],
    ) -> Result<(i32, Vec<SharePartitionData>), Status> {
        let mut c = conn.lock().await;
        let ver = c.negotiate(API_SHARE_FETCH, 2)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.cstr(member_id);
        body.i32(session_epoch);
        body.i32(max_wait_ms);
        body.i32(1); // min_bytes
        body.i32(4 * 1024 * 1024); // max_bytes
        body.i32(max_records);
        body.i32(0); // batch_size
        if ver >= 2 {
            body.i8(0); // share_acquire_mode
            body.i8(0); // is_renew_ack
        }
        body.carr(topics.len());
        for (id, partitions) in topics {
            body.bytes(id);
            body.carr(partitions.len());
            for partition in partitions {
                body.i32(*partition);
                let batches: &[ShareAckBatch] = acks
                    .iter()
                    .find(|(t, p, _)| t == id && p == partition)
                    .map(|(_, _, b)| b.as_slice())
                    .unwrap_or(&[]);
                write_ack_batches(&mut body, batches);
                body.tagged_none();
            }
            body.tagged_none();
        }
        body.carr(0); // forgotten_topics_data
        body.tagged_none();
        let resp = c.request(API_SHARE_FETCH, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        let _msg = r.cstr_opt().map_err(bad)?;
        let _acquisition_lock_timeout_ms = r.i32().map_err(bad)?;
        let mut out = Vec::new();
        let ntopics = r.carr_len().map_err(bad)?;
        for _ in 0..ntopics {
            let id_bytes = r.take(16).map_err(bad)?;
            let mut topic_id = [0u8; 16];
            topic_id.copy_from_slice(id_bytes);
            let nparts = r.carr_len().map_err(bad)?;
            for _ in 0..nparts {
                let partition = r.i32().map_err(bad)?;
                let perr = r.i16().map_err(bad)? as i32;
                let _perr_msg = r.cstr_opt().map_err(bad)?;
                let _ack_err = r.i16().map_err(bad)?;
                let _ack_msg = r.cstr_opt().map_err(bad)?;
                let _leader = r.i32().map_err(bad)?;
                let _leader_epoch = r.i32().map_err(bad)?;
                r.skip_tagged().map_err(bad)?; // CurrentLeader
                let records_bytes = r.cbytes_opt().map_err(bad)?.unwrap_or_default();
                let mut acquired: Vec<(i64, i64, i32)> = Vec::new();
                if let Some(na) = r.carr().map_err(bad)? {
                    for _ in 0..na {
                        let first = r.i64().map_err(bad)?;
                        let last = r.i64().map_err(bad)?;
                        let delivery = r.i16().map_err(bad)? as i32;
                        r.skip_tagged().map_err(bad)?;
                        acquired.push((first, last, delivery));
                    }
                }
                r.skip_tagged().map_err(bad)?;
                let mut records = Vec::new();
                if perr == 0 && !records_bytes.is_empty() {
                    for tagged in parse_record_batches_tagged(&records_bytes).map_err(bad)? {
                        if tagged.control {
                            continue;
                        }
                        let delivery = acquired
                            .iter()
                            .find(|(first, last, _)| {
                                tagged.offset >= *first && tagged.offset <= *last
                            })
                            .map(|(_, _, d)| *d)
                            .unwrap_or(1);
                        records.push((tagged.record, tagged.offset, delivery));
                    }
                }
                out.push(SharePartitionData {
                    topic_id,
                    partition,
                    error_code: perr,
                    records,
                });
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok((error_code, out))
    }

    /// KIP-932 ShareAcknowledge (API 79): acknowledge records
    /// outside a fetch round.
    pub async fn share_acknowledge(
        &self,
        conn: &Arc<Mutex<Conn>>,
        group_id: &str,
        member_id: &str,
        session_epoch: i32,
        acks: &[([u8; 16], i32, Vec<ShareAckBatch>)],
    ) -> Result<i32, Status> {
        let mut c = conn.lock().await;
        let ver = c.negotiate(API_SHARE_ACKNOWLEDGE, 2)?;
        let mut body = W::new();
        body.cstr(group_id);
        body.cstr(member_id);
        body.i32(session_epoch);
        if ver >= 2 {
            body.i8(0); // is_renew_ack
        }
        // Group ack entries by topic id.
        let mut by_topic: Vec<([u8; 16], Vec<&([u8; 16], i32, Vec<ShareAckBatch>)>)> =
            Vec::new();
        for entry in acks {
            match by_topic.iter_mut().find(|(id, _)| *id == entry.0) {
                Some((_, parts)) => parts.push(entry),
                None => by_topic.push((entry.0, vec![entry])),
            }
        }
        body.carr(by_topic.len());
        for (id, parts) in &by_topic {
            body.bytes(id);
            body.carr(parts.len());
            for (_, partition, batches) in parts {
                body.i32(*partition);
                write_ack_batches(&mut body, batches);
                body.tagged_none();
            }
            body.tagged_none();
        }
        body.tagged_none();
        let resp = c.request(API_SHARE_ACKNOWLEDGE, ver, body, true).await?;
        let mut r = R::new(&resp);
        let _throttle = r.i32().map_err(bad)?;
        let error_code = r.i16().map_err(bad)? as i32;
        let _msg = r.cstr_opt().map_err(bad)?;
        if ver >= 2 {
            let _acquisition_lock_timeout_ms = r.i32().map_err(bad)?;
        }
        let ntopics = r.carr_len().map_err(bad)?;
        let mut first_error = error_code;
        for _ in 0..ntopics {
            let _id = r.take(16).map_err(bad)?;
            let nparts = r.carr_len().map_err(bad)?;
            for _ in 0..nparts {
                let _partition = r.i32().map_err(bad)?;
                let perr = r.i16().map_err(bad)? as i32;
                if first_error == 0 && perr != 0 {
                    first_error = perr;
                }
                let _perr_msg = r.cstr_opt().map_err(bad)?;
                let _leader = r.i32().map_err(bad)?;
                let _leader_epoch = r.i32().map_err(bad)?;
                r.skip_tagged().map_err(bad)?; // CurrentLeader
                r.skip_tagged().map_err(bad)?;
            }
            r.skip_tagged().map_err(bad)?;
        }
        Ok(first_error)
    }
}

/// KIP-932 ShareFetch result for one partition.
pub struct SharePartitionData {
    pub topic_id: [u8; 16],
    pub partition: i32,
    pub error_code: i32,
    /// (record, offset, delivery_count)
    pub records: Vec<(crate::pb::FetchedRecord, i64, i32)>,
}

/// One ShareAcknowledge batch: [first, last] offsets sharing
/// an ack type (1 ACCEPT, 2 RELEASE, 3 REJECT).
pub struct ShareAckBatch {
    pub first_offset: i64,
    pub last_offset: i64,
    pub ack_type: u8,
}

fn write_ack_batches(body: &mut W, batches: &[ShareAckBatch]) {
    body.carr(batches.len());
    for batch in batches {
        body.i64(batch.first_offset);
        body.i64(batch.last_offset);
        body.cbytes(&[batch.ack_type]);
        body.tagged_none();
    }
}

/// One ConsumerGroupDescribe Assignment/TargetAssignment
/// block: topic id (+ name where the broker sends it) ->
/// partitions.
fn read_describe_assignment(
    r: &mut R<'_>,
) -> Result<Vec<([u8; 16], String, Vec<i32>)>, Status> {
    // Plain struct: TopicPartitions array of
    // {TopicId, TopicName, Partitions[]}.
    let mut out = Vec::new();
    let n = r.carr_len().map_err(bad)?;
    for _ in 0..n {
        let id_bytes = r.take(16).map_err(bad)?;
        let mut id = [0u8; 16];
        id.copy_from_slice(id_bytes);
        let name = r.cstr().map_err(bad)?;
        let np = r.carr_len().map_err(bad)?;
        let mut partitions = Vec::new();
        for _ in 0..np {
            partitions.push(r.i32().map_err(bad)?);
        }
        r.skip_tagged().map_err(bad)?;
        out.push((id, name, partitions));
    }
    r.skip_tagged().map_err(bad)?;
    Ok(out)
}

/// KIP-848 ConsumerGroupHeartbeat response.
pub struct ConsumerHeartbeat {
    pub error_code: i32,
    pub error_message: String,
    pub member_id: String,
    pub member_epoch: i32,
    pub heartbeat_interval_ms: i32,
    /// None = assignment unchanged; Some replaces it.
    pub assignment: Option<Vec<([u8; 16], Vec<i32>)>>,
}

/// Consumer-protocol Subscription (v0) encoding used in
/// JoinGroup protocol metadata.
pub fn encode_subscription(topics: &[String]) -> Vec<u8> {
    let mut w = W::new();
    w.i16(0); // version
    w.arr32(topics.len());
    for t in topics {
        w.str16(t);
    }
    w.bytes32(&[]); // user_data (null-ish: length 0)
    // v0 has no owned_partitions; brokers accept v0 from us.
    w.0
}

pub fn decode_subscription(data: &[u8]) -> Vec<String> {
    let mut r = R::new(data);
    if r.i16().is_err() {
        return Vec::new();
    }
    let n = match r.arr32() {
        Ok(n) if n >= 0 => n as usize,
        _ => return Vec::new(),
    };
    let mut out = Vec::new();
    for _ in 0..n {
        match r.str16() {
            Ok(t) => out.push(t),
            Err(_) => break,
        }
    }
    out
}

/// Consumer-protocol Assignment (v0) encoding.
pub fn encode_assignment(partitions: &[(String, i32)]) -> Vec<u8> {
    let mut by_topic: HashMap<&str, Vec<i32>> = HashMap::new();
    for (t, p) in partitions {
        by_topic.entry(t.as_str()).or_default().push(*p);
    }
    let mut w = W::new();
    w.i16(0);
    w.arr32(by_topic.len());
    for (t, parts) in &by_topic {
        w.str16(t);
        w.arr32(parts.len());
        for p in parts {
            w.i32(*p);
        }
    }
    w.bytes32(&[]);
    w.0
}

pub fn decode_assignment(data: &[u8]) -> Vec<(String, i32)> {
    let mut r = R::new(data);
    if r.i16().is_err() {
        return Vec::new();
    }
    let n = match r.arr32() {
        Ok(n) if n >= 0 => n as usize,
        _ => return Vec::new(),
    };
    let mut out = Vec::new();
    for _ in 0..n {
        let topic = match r.str16() {
            Ok(t) => t,
            Err(_) => break,
        };
        let np = match r.arr32() {
            Ok(n) if n >= 0 => n as usize,
            _ => break,
        };
        for _ in 0..np {
            match r.i32() {
                Ok(p) => out.push((topic.clone(), p)),
                Err(_) => break,
            }
        }
    }
    out
}
