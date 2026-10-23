//! Hand-rolled cryptography (zero crates): SHA-256, SHA-1, HMAC,
//! TLS 1.2 PRF, AES-128, AES-GCM, CRC-32. Round constants, the S-box and
//! the CRC table come from `proto_gen` — computed by the Racket
//! metaprogram from the defining mathematics, never transcribed.
//!
//! Everything here is verified against published vectors in the tests
//! below, and again end-to-end by the OpenSSL DTLS oracle tests.

use alloc::vec::Vec;
use crate::proto_gen::{AES_SBOX, CRC32_TABLE, SHA256_H, SHA256_K, SHA384_H, SHA512_H, SHA512_K};

// ---------------------------------------------------------------------------
// entropy
// ---------------------------------------------------------------------------

pub fn random_bytes(n: usize) -> Vec<u8> {
    // Routed through the platform RNG (installed via
    // platform::install_rng; /dev/urandom by default) so embedded
    // targets can substitute a hardware TRNG.
    crate::platform::random_bytes(n)
}

pub fn random_u64() -> u64 {
    let b = random_bytes(8);
    u64::from_be_bytes(b.try_into().unwrap())
}

// ---------------------------------------------------------------------------
// SHA-256
// ---------------------------------------------------------------------------

pub struct Sha256 {
    state: [u32; 8],
    buf: [u8; 64],
    buflen: usize,
    total: u64,
}

impl Sha256 {
    pub fn new() -> Self {
        Self { state: SHA256_H, buf: [0u8; 64], buflen: 0, total: 0 }
    }

    pub fn update(&mut self, mut data: &[u8]) {
        self.total = self.total.wrapping_add(data.len() as u64);
        if self.buflen > 0 {
            let take = (64 - self.buflen).min(data.len());
            self.buf[self.buflen..self.buflen + take].copy_from_slice(&data[..take]);
            self.buflen += take;
            data = &data[take..];
            if self.buflen == 64 {
                let block = self.buf;
                self.compress(&block);
                self.buflen = 0;
            }
        }
        while data.len() >= 64 {
            let mut block = [0u8; 64];
            block.copy_from_slice(&data[..64]);
            self.compress(&block);
            data = &data[64..];
        }
        if !data.is_empty() {
            self.buf[..data.len()].copy_from_slice(data);
            self.buflen = data.len();
        }
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h) = (
            self.state[0], self.state[1], self.state[2], self.state[3], self.state[4],
            self.state[5], self.state[6], self.state[7],
        );
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (i, v) in [a, b, c, d, e, f, g, h].iter().enumerate() {
            self.state[i] = self.state[i].wrapping_add(*v);
        }
    }

    pub fn finalize(mut self) -> [u8; 32] {
        let bitlen = self.total.wrapping_mul(8);
        self.update(&[0x80]);
        while self.buflen != 56 {
            self.update(&[0]);
        }
        // Append length manually: total was already counted, so write
        // the 8 length bytes through the block buffer directly.
        self.buf[56..64].copy_from_slice(&bitlen.to_be_bytes());
        let block = self.buf;
        self.compress(&block);
        let mut out = [0u8; 32];
        for i in 0..8 {
            out[i * 4..i * 4 + 4].copy_from_slice(&self.state[i].to_be_bytes());
        }
        out
    }
}

fn sha256_native(data: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(data);
    h.finalize()
}

// ---------------------------------------------------------------------------
// SHA-512 / SHA-384 (FIPS 180-4; certificate chain verification)
// ---------------------------------------------------------------------------

pub struct Sha512 {
    state: [u64; 8],
    buf: [u8; 128],
    buflen: usize,
    total: u64,
}

impl Sha512 {
    pub fn new() -> Self {
        Self::with_iv(SHA512_H)
    }

    pub fn new384() -> Self {
        Self::with_iv(SHA384_H)
    }

    fn with_iv(state: [u64; 8]) -> Self {
        Self { state, buf: [0u8; 128], buflen: 0, total: 0 }
    }

    pub fn update(&mut self, mut data: &[u8]) {
        self.total = self.total.wrapping_add(data.len() as u64);
        if self.buflen > 0 {
            let take = (128 - self.buflen).min(data.len());
            self.buf[self.buflen..self.buflen + take].copy_from_slice(&data[..take]);
            self.buflen += take;
            data = &data[take..];
            if self.buflen == 128 {
                let block = self.buf;
                self.compress(&block);
                self.buflen = 0;
            }
        }
        while data.len() >= 128 {
            let mut block = [0u8; 128];
            block.copy_from_slice(&data[..128]);
            self.compress(&block);
            data = &data[128..];
        }
        if !data.is_empty() {
            self.buf[..data.len()].copy_from_slice(data);
            self.buflen = data.len();
        }
    }

    fn compress(&mut self, block: &[u8; 128]) {
        let mut w = [0u64; 80];
        for i in 0..16 {
            w[i] = u64::from_be_bytes(block[i * 8..i * 8 + 8].try_into().unwrap());
        }
        for i in 16..80 {
            let s0 = w[i - 15].rotate_right(1) ^ w[i - 15].rotate_right(8) ^ (w[i - 15] >> 7);
            let s1 = w[i - 2].rotate_right(19) ^ w[i - 2].rotate_right(61) ^ (w[i - 2] >> 6);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h) = (
            self.state[0], self.state[1], self.state[2], self.state[3], self.state[4],
            self.state[5], self.state[6], self.state[7],
        );
        for i in 0..80 {
            let s1 = e.rotate_right(14) ^ e.rotate_right(18) ^ e.rotate_right(41);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA512_K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(28) ^ a.rotate_right(34) ^ a.rotate_right(39);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (i, v) in [a, b, c, d, e, f, g, h].iter().enumerate() {
            self.state[i] = self.state[i].wrapping_add(*v);
        }
    }

    pub fn finalize(mut self) -> [u8; 64] {
        let bitlen = (self.total as u128).wrapping_mul(8);
        self.update(&[0x80]);
        while self.buflen != 112 {
            self.update(&[0]);
        }
        self.buf[112..128].copy_from_slice(&bitlen.to_be_bytes());
        let block = self.buf;
        self.compress(&block);
        let mut out = [0u8; 64];
        for i in 0..8 {
            out[i * 8..i * 8 + 8].copy_from_slice(&self.state[i].to_be_bytes());
        }
        out
    }
}

pub fn sha512(data: &[u8]) -> [u8; 64] {
    let mut h = Sha512::new();
    h.update(data);
    h.finalize()
}

pub fn sha384(data: &[u8]) -> [u8; 48] {
    let mut h = Sha512::new384();
    h.update(data);
    h.finalize()[..48].try_into().unwrap()
}

// ---------------------------------------------------------------------------
// MD5 (RFC 1321; TURN long-term credential key only — the K/S
// tables are computed by the Racket metaprogram in proto_gen)
// ---------------------------------------------------------------------------

pub fn md5(data: &[u8]) -> [u8; 16] {
    use crate::proto_gen::{MD5_K, MD5_S};
    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;
    let bitlen = (data.len() as u64).wrapping_mul(8);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_le_bytes());
    for block in msg.chunks_exact(64) {
        let mut m = [0u32; 16];
        for i in 0..16 {
            m[i] = u32::from_le_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
        }
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let sum = a
                .wrapping_add(f)
                .wrapping_add(MD5_K[i])
                .wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(sum.rotate_left(MD5_S[i]));
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }
    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&a0.to_le_bytes());
    out[4..8].copy_from_slice(&b0.to_le_bytes());
    out[8..12].copy_from_slice(&c0.to_le_bytes());
    out[12..16].copy_from_slice(&d0.to_le_bytes());
    out
}

// ---------------------------------------------------------------------------
// SHA-1 (STUN MESSAGE-INTEGRITY)
// ---------------------------------------------------------------------------

pub fn sha1(data: &[u8]) -> [u8; 20] {
    let mut h: [u32; 5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    let bitlen = (data.len() as u64).wrapping_mul(8);
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    for chunk in msg.chunks_exact(64) {
        let mut w = [0u32; 80];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (i, &wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | ((!b) & d), 0x5A827999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
                _ => (b ^ c ^ d, 0xCA62C1D6),
            };
            let tmp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = tmp;
        }
        for (i, v) in [a, b, c, d, e].iter().enumerate() {
            h[i] = h[i].wrapping_add(*v);
        }
    }
    let mut out = [0u8; 20];
    for i in 0..5 {
        out[i * 4..i * 4 + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

// ---------------------------------------------------------------------------
// HMAC + TLS 1.2 PRF (SHA-256)
// ---------------------------------------------------------------------------

fn hmac_sha256_native(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    hmac(key, parts, true)
}

pub fn hmac_sha1(key: &[u8], parts: &[&[u8]]) -> [u8; 20] {
    let out = hmac(key, parts, false);
    out[..20].try_into().unwrap()
}

fn hmac(key: &[u8], parts: &[&[u8]], use256: bool) -> [u8; 32] {
    let block = 64usize;
    let mut k = if use256 {
        if key.len() > block {
            sha256_native(key).to_vec()
        } else {
            key.to_vec()
        }
    } else if key.len() > block {
        sha1(key).to_vec()
    } else {
        key.to_vec()
    };
    k.resize(block, 0);
    let ipad: Vec<u8> = k.iter().map(|b| b ^ 0x36).collect();
    let opad: Vec<u8> = k.iter().map(|b| b ^ 0x5c).collect();
    if use256 {
        let mut inner = Sha256::new();
        inner.update(&ipad);
        for p in parts {
            inner.update(p);
        }
        let inner_hash = inner.finalize();
        let mut outer = Sha256::new();
        outer.update(&opad);
        outer.update(&inner_hash);
        outer.finalize()
    } else {
        let mut inner_input = ipad;
        for p in parts {
            inner_input.extend_from_slice(p);
        }
        let inner_hash = sha1(&inner_input);
        let mut outer_input = opad;
        outer_input.extend_from_slice(&inner_hash);
        let digest = sha1(&outer_input);
        let mut out = [0u8; 32];
        out[..20].copy_from_slice(&digest);
        out
    }
}

fn p_hash(secret: &[u8], seed: &[u8], out_len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(out_len);
    let mut a = hmac_sha256_native(secret, &[seed]).to_vec();
    while out.len() < out_len {
        let chunk = hmac_sha256_native(secret, &[&a, seed]);
        out.extend_from_slice(&chunk);
        a = hmac_sha256_native(secret, &[&a]).to_vec();
    }
    out.truncate(out_len);
    out
}

/// TLS 1.2 PRF with SHA-256 (RFC 5246 section 5), native impl.
fn prf_native(secret: &[u8], label: &str, seed: &[u8], out_len: usize) -> Vec<u8> {
    let mut full_seed = label.as_bytes().to_vec();
    full_seed.extend_from_slice(seed);
    p_hash(secret, &full_seed, out_len)
}

// ---------------------------------------------------------------------------
// AES-128 block encryption (GCM needs only the forward direction)
// ---------------------------------------------------------------------------

pub struct Aes128 {
    round_keys: [[u8; 16]; 11],
}

impl Aes128 {
    pub fn new(key: &[u8; 16]) -> Self {
        let mut w = [[0u8; 4]; 44];
        for i in 0..4 {
            w[i] = [key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]];
        }
        const RCON: [u8; 10] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];
        for i in 4..44 {
            let mut temp = w[i - 1];
            if i % 4 == 0 {
                temp = [
                    AES_SBOX[temp[1] as usize] ^ RCON[i / 4 - 1],
                    AES_SBOX[temp[2] as usize],
                    AES_SBOX[temp[3] as usize],
                    AES_SBOX[temp[0] as usize],
                ];
            }
            for j in 0..4 {
                w[i][j] = w[i - 4][j] ^ temp[j];
            }
        }
        let mut round_keys = [[0u8; 16]; 11];
        for r in 0..11 {
            for c in 0..4 {
                for j in 0..4 {
                    round_keys[r][4 * c + j] = w[4 * r + c][j];
                }
            }
        }
        Self { round_keys }
    }

    pub fn encrypt_block(&self, input: &[u8; 16]) -> [u8; 16] {
        let mut s = *input;
        add_round_key(&mut s, &self.round_keys[0]);
        for round in 1..10 {
            sub_bytes(&mut s);
            shift_rows(&mut s);
            mix_columns(&mut s);
            add_round_key(&mut s, &self.round_keys[round]);
        }
        sub_bytes(&mut s);
        shift_rows(&mut s);
        add_round_key(&mut s, &self.round_keys[10]);
        s
    }
}

fn add_round_key(s: &mut [u8; 16], rk: &[u8; 16]) {
    for i in 0..16 {
        s[i] ^= rk[i];
    }
}

fn sub_bytes(s: &mut [u8; 16]) {
    for b in s.iter_mut() {
        *b = AES_SBOX[*b as usize];
    }
}

fn shift_rows(s: &mut [u8; 16]) {
    let t = *s;
    // state index = row + 4*col; row r rotates left by r
    for r in 0..4 {
        for c in 0..4 {
            s[r + 4 * c] = t[r + 4 * ((c + r) % 4)];
        }
    }
}

fn xtime(x: u8) -> u8 {
    (x << 1) ^ if x & 0x80 != 0 { 0x1b } else { 0x00 }
}

fn mix_columns(s: &mut [u8; 16]) {
    for c in 0..4 {
        let i = 4 * c;
        let (a0, a1, a2, a3) = (s[i], s[i + 1], s[i + 2], s[i + 3]);
        s[i] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
        s[i + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
        s[i + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
        s[i + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
    }
}

// ---------------------------------------------------------------------------
// AES-GCM (RFC 5116), 96-bit nonces as used by DTLS
// ---------------------------------------------------------------------------

fn gf128_mul(x: &[u8; 16], y: &[u8; 16]) -> [u8; 16] {
    let mut z = [0u8; 16];
    let mut v = *y;
    for i in 0..128 {
        let bit = (x[i / 8] >> (7 - (i % 8))) & 1;
        if bit == 1 {
            for j in 0..16 {
                z[j] ^= v[j];
            }
        }
        let lsb = v[15] & 1;
        for j in (1..16).rev() {
            v[j] = (v[j] >> 1) | ((v[j - 1] & 1) << 7);
        }
        v[0] >>= 1;
        if lsb == 1 {
            v[0] ^= 0xe1;
        }
    }
    z
}

fn ghash(h: &[u8; 16], aad: &[u8], ciphertext: &[u8]) -> [u8; 16] {
    let mut y = [0u8; 16];
    let feed = |y: &mut [u8; 16], data: &[u8]| {
        for chunk in data.chunks(16) {
            let mut block = [0u8; 16];
            block[..chunk.len()].copy_from_slice(chunk);
            for j in 0..16 {
                y[j] ^= block[j];
            }
            *y = gf128_mul(y, h);
        }
    };
    feed(&mut y, aad);
    feed(&mut y, ciphertext);
    let mut lens = [0u8; 16];
    lens[0..8].copy_from_slice(&((aad.len() as u64) * 8).to_be_bytes());
    lens[8..16].copy_from_slice(&((ciphertext.len() as u64) * 8).to_be_bytes());
    for j in 0..16 {
        y[j] ^= lens[j];
    }
    gf128_mul(&y, h)
}

fn inc32(block: &mut [u8; 16]) {
    let n = u32::from_be_bytes(block[12..16].try_into().unwrap()).wrapping_add(1);
    block[12..16].copy_from_slice(&n.to_be_bytes());
}

fn gctr(aes: &Aes128, icb: &[u8; 16], input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len());
    let mut cb = *icb;
    for chunk in input.chunks(16) {
        inc32(&mut cb);
        let keystream = aes.encrypt_block(&cb);
        for (i, &b) in chunk.iter().enumerate() {
            out.push(b ^ keystream[i]);
        }
    }
    out
}

fn aes128_gcm_encrypt_native(
    key: &[u8; 16],
    nonce: &[u8; 12],
    plaintext: &[u8],
    aad: &[u8],
) -> (Vec<u8>, [u8; 16]) {
    let aes = Aes128::new(key);
    let h = aes.encrypt_block(&[0u8; 16]);
    let mut j0 = [0u8; 16];
    j0[..12].copy_from_slice(nonce);
    j0[15] = 1;
    let ciphertext = gctr(&aes, &j0, plaintext);
    let s = ghash(&h, aad, &ciphertext);
    let tag_mask = aes.encrypt_block(&j0);
    let mut tag = [0u8; 16];
    for i in 0..16 {
        tag[i] = s[i] ^ tag_mask[i];
    }
    (ciphertext, tag)
}

fn aes128_gcm_decrypt_native(
    key: &[u8; 16],
    nonce: &[u8; 12],
    ciphertext: &[u8],
    aad: &[u8],
    tag: &[u8; 16],
) -> Option<Vec<u8>> {
    let aes = Aes128::new(key);
    let h = aes.encrypt_block(&[0u8; 16]);
    let mut j0 = [0u8; 16];
    j0[..12].copy_from_slice(nonce);
    j0[15] = 1;
    let s = ghash(&h, aad, ciphertext);
    let tag_mask = aes.encrypt_block(&j0);
    let mut expected = [0u8; 16];
    for i in 0..16 {
        expected[i] = s[i] ^ tag_mask[i];
    }
    if expected != *tag {
        return None;
    }
    Some(gctr(&aes, &j0, ciphertext))
}


// ---------------------------------------------------------------------------
// Pluggable crypto backend
// ---------------------------------------------------------------------------

/// Crypto operations the DTLS 1.2 ECDHE-ECDSA AES-128-GCM-SHA256
/// suite (and session tickets) are built from. The default
/// backend is the hand-rolled implementation in this module;
/// embedded vendors can install their own (mbedTLS/PSA/wolfSSL
/// bindings) once at startup via `install_backend`, and every
/// call site in the crate picks it up without code changes.
///
/// Outside this v1 boundary (still hand-rolled): SHA-384/512,
/// SHA-1/MD5 (certificate-chain and STUN legacy paths), CRCs, and
/// the P-256/P-384 group operations in p256.rs/p384.rs.
pub trait CryptoBackend: Send + Sync {
    fn sha256(&self, data: &[u8]) -> [u8; 32];
    fn hmac_sha256(&self, key: &[u8], parts: &[&[u8]]) -> [u8; 32];
    fn prf(&self, secret: &[u8], label: &str, seed: &[u8], out_len: usize) -> Vec<u8>;
    fn aes128_gcm_encrypt(
        &self,
        key: &[u8; 16],
        nonce: &[u8; 12],
        plaintext: &[u8],
        aad: &[u8],
    ) -> (Vec<u8>, [u8; 16]);
    fn aes128_gcm_decrypt(
        &self,
        key: &[u8; 16],
        nonce: &[u8; 12],
        ciphertext: &[u8],
        aad: &[u8],
        tag: &[u8; 16],
    ) -> Option<Vec<u8>>;
}

/// The hand-rolled zero-dependency backend (default).
pub struct HandRolledBackend;

impl CryptoBackend for HandRolledBackend {
    fn sha256(&self, data: &[u8]) -> [u8; 32] {
        sha256_native(data)
    }

    fn hmac_sha256(&self, key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
        hmac_sha256_native(key, parts)
    }

    fn prf(&self, secret: &[u8], label: &str, seed: &[u8], out_len: usize) -> Vec<u8> {
        prf_native(secret, label, seed, out_len)
    }

    fn aes128_gcm_encrypt(
        &self,
        key: &[u8; 16],
        nonce: &[u8; 12],
        plaintext: &[u8],
        aad: &[u8],
    ) -> (Vec<u8>, [u8; 16]) {
        aes128_gcm_encrypt_native(key, nonce, plaintext, aad)
    }

    fn aes128_gcm_decrypt(
        &self,
        key: &[u8; 16],
        nonce: &[u8; 12],
        ciphertext: &[u8],
        aad: &[u8],
        tag: &[u8; 16],
    ) -> Option<Vec<u8>> {
        aes128_gcm_decrypt_native(key, nonce, ciphertext, aad, tag)
    }
}

static BACKEND: crate::platform::Mutex<Option<alloc::sync::Arc<dyn CryptoBackend>>> =
    crate::platform::Mutex::new(None);

/// Install the process-wide crypto backend. Call once at startup;
/// returns false when a backend was already installed.
pub fn install_backend(backend: alloc::sync::Arc<dyn CryptoBackend>) -> bool {
    let mut slot = BACKEND.lock();
    if slot.is_some() {
        return false;
    }
    *slot = Some(backend);
    true
}

/// The installed crypto backend (default: `HandRolledBackend`).
pub fn backend() -> alloc::sync::Arc<dyn CryptoBackend> {
    let mut slot = BACKEND.lock();
    if slot.is_none() {
        *slot = Some(alloc::sync::Arc::new(HandRolledBackend));
    }
    slot.as_ref().expect("backend installed").clone()
}

/// SHA-256 through the installed backend.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    backend().sha256(data)
}

/// HMAC-SHA-256 through the installed backend.
pub fn hmac_sha256(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    backend().hmac_sha256(key, parts)
}

/// TLS 1.2 PRF (SHA-256) through the installed backend.
pub fn prf(secret: &[u8], label: &str, seed: &[u8], out_len: usize) -> Vec<u8> {
    backend().prf(secret, label, seed, out_len)
}

/// AES-128-GCM encrypt through the installed backend.
pub fn aes128_gcm_encrypt(
    key: &[u8; 16],
    nonce: &[u8; 12],
    plaintext: &[u8],
    aad: &[u8],
) -> (Vec<u8>, [u8; 16]) {
    backend().aes128_gcm_encrypt(key, nonce, plaintext, aad)
}

/// AES-128-GCM decrypt through the installed backend.
pub fn aes128_gcm_decrypt(
    key: &[u8; 16],
    nonce: &[u8; 12],
    ciphertext: &[u8],
    aad: &[u8],
    tag: &[u8; 16],
) -> Option<Vec<u8>> {
    backend().aes128_gcm_decrypt(key, nonce, ciphertext, aad, tag)
}

// ---------------------------------------------------------------------------
// CRC-32 (STUN FINGERPRINT, after XOR with 0x5354554e)
// ---------------------------------------------------------------------------

pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc = CRC32_TABLE[((crc ^ b as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

/// CRC-32C (Castagnoli) — the SCTP checksum (stored little-endian on
/// the wire, unlike most SCTP fields).
pub fn crc32c(data: &[u8]) -> u32 {
    use crate::proto_gen::CRC32C_TABLE;
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc = CRC32C_TABLE[((crc ^ b as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn sha512_vectors() {
        // FIPS 180-4 published examples ("abc").
        assert_eq!(
            hex(&sha512(b"abc")),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                .to_string()
                + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        );
        assert_eq!(
            hex(&sha384(b"abc")),
            "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
                .to_string()
                + "8086072ba1e7cc2358baeca134c825a7"
        );
        // Streaming in odd chunks must agree with one-shot.
        let mut h = Sha512::new();
        for chunk in [b"a".as_slice(), b"b".as_slice(), b"c".as_slice()] {
            h.update(chunk);
        }
        assert_eq!(h.finalize(), sha512(b"abc"));
    }

    #[test]
    fn sha256_vectors() {
        assert_eq!(hex(&sha256(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(hex(&sha256(b"")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        let long = vec![b'a'; 1_000_000];
        assert_eq!(hex(&sha256(&long)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
        // streaming in odd chunks equals one-shot
        let mut h = Sha256::new();
        for chunk in long.chunks(999) {
            h.update(chunk);
        }
        assert_eq!(h.finalize(), sha256(&long));
    }

    #[test]
    fn md5_vectors() {
        // RFC 1321 test suite.
        assert_eq!(hex(&md5(b"")), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(hex(&md5(b"abc")), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            hex(&md5(b"The quick brown fox jumps over the lazy dog")),
            "9e107d9d372bb6826bd81d3542a419d6"
        );
    }

    #[test]
    fn sha1_vectors() {
        assert_eq!(hex(&sha1(b"abc")), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(hex(&sha1(b"")), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    }

    #[test]
    fn hmac_vectors() {
        // RFC 4231 test case 1
        let key = [0x0bu8; 20];
        assert_eq!(
            hex(&hmac_sha256(&key, &[b"Hi There"])),
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        );
        // RFC 2202 test case 1
        assert_eq!(
            hex(&hmac_sha1(&key, &[b"Hi There"])),
            "b617318655057264e28bc0b6fb378c8ef146be00"
        );
    }

    #[test]
    fn aes_vector() {
        // FIPS-197 appendix example
        let key: [u8; 16] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f];
        let pt: [u8; 16] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
        assert_eq!(hex(&Aes128::new(&key).encrypt_block(&pt)), "69c4e0d86a7b0430d8cdb78070b4c55a");
    }

    #[test]
    fn gcm_vector() {
        // NIST GCM test case 2 (zero key/IV/plaintext block); values
        // cross-checked against Node's crypto implementation.
        let (ct, tag) = aes128_gcm_encrypt(&[0u8; 16], &[0u8; 12], &[0u8; 16], &[]);
        assert_eq!(hex(&ct), "0388dace60b6a392f328c2b971b2fe78");
        assert_eq!(hex(&tag), "ab6e47d42cec13bdf53a67b21257bddf");
        let pt = aes128_gcm_decrypt(&[0u8; 16], &[0u8; 12], &ct, &[], &tag).unwrap();
        assert_eq!(pt, vec![0u8; 16]);
        let mut bad = tag;
        bad[0] ^= 1;
        assert!(aes128_gcm_decrypt(&[0u8; 16], &[0u8; 12], &ct, &[], &bad).is_none());
    }

    #[test]
    fn crc32_vector() {
        assert_eq!(crc32(b"123456789"), 0xCBF43926);
        assert_eq!(crc32(b""), 0);
        assert_eq!(crc32c(b"123456789"), 0xE3069283);
    }
}
