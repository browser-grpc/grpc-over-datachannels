//! SHA-256 / SHA-512, HMAC, PBKDF2 — needed for Kafka
//! SASL/SCRAM. Round constants are derived at runtime from
//! the fractional parts of prime roots (exact integer
//! arithmetic), avoiding error-prone constant tables.

use std::sync::OnceLock;

// --- minimal U256 (for 512-bit constant derivation) ---------

#[derive(Clone, Copy, PartialEq, Eq)]
struct U256([u64; 4]); // little-endian limbs

impl PartialOrd for U256 {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for U256 {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Most significant limb decides.
        for i in (0..4).rev() {
            match self.0[i].cmp(&other.0[i]) {
                std::cmp::Ordering::Equal => continue,
                ord => return ord,
            }
        }
        std::cmp::Ordering::Equal
    }
}

impl U256 {
    const ZERO: U256 = U256([0; 4]);
    fn from_u128(v: u128) -> U256 {
        U256([v as u64, (v >> 64) as u64, 0, 0])
    }
    fn shl1(&self) -> U256 {
        let mut out = [0u64; 4];
        let mut carry = 0u64;
        for i in 0..4 {
            out[i] = (self.0[i] << 1) | carry;
            carry = self.0[i] >> 63;
        }
        U256(out)
    }
    fn shr1(&self) -> U256 {
        let mut out = [0u64; 4];
        let mut carry = 0u64;
        for i in (0..4).rev() {
            out[i] = (self.0[i] >> 1) | carry;
            carry = self.0[i] << 63;
        }
        U256(out)
    }
    fn add(&self, other: &U256) -> U256 {
        let mut out = [0u64; 4];
        let mut carry = 0u128;
        for i in 0..4 {
            let s = self.0[i] as u128 + other.0[i] as u128 + carry;
            out[i] = s as u64;
            carry = s >> 64;
        }
        U256(out)
    }
    fn sub(&self, other: &U256) -> U256 {
        let mut out = [0u64; 4];
        let mut borrow = 0i128;
        for i in 0..4 {
            let d = self.0[i] as i128 - other.0[i] as i128 - borrow;
            if d < 0 {
                out[i] = (d + (1i128 << 64)) as u64;
                borrow = 1;
            } else {
                out[i] = d as u64;
                borrow = 0;
            }
        }
        U256(out)
    }
    fn mul(&self, other: &U256) -> U256 {
        let mut out = [0u64; 4];
        for i in 0..4 {
            let mut carry = 0u128;
            for j in 0..(4 - i) {
                let idx = i + j;
                let t = self.0[i] as u128 * other.0[j] as u128 + out[idx] as u128 + carry;
                out[idx] = t as u64;
                carry = t >> 64;
            }
        }
        U256(out)
    }
    fn shl(&self, bits: usize) -> U256 {
        let limb = bits / 64;
        let rem = bits % 64;
        let mut out = [0u64; 4];
        for i in (limb..4).rev() {
            let mut v = self.0[i - limb] << rem;
            if rem > 0 && i > limb {
                v |= self.0[i - limb - 1] >> (64 - rem);
            }
            out[i] = v;
        }
        U256(out)
    }
    fn shr2(&self) -> U256 {
        let mut out = [0u64; 4];
        for i in 0..3 {
            out[i] = (self.0[i] >> 2) | (self.0[i + 1] << 62);
        }
        out[3] = self.0[3] >> 2;
        U256(out)
    }
    fn bit(&self, i: usize) -> bool {
        (self.0[i / 64] >> (i % 64)) & 1 == 1
    }
    fn bitlen(&self) -> usize {
        for i in (0..4).rev() {
            if self.0[i] != 0 {
                return i * 64 + (64 - self.0[i].leading_zeros() as usize);
            }
        }
        0
    }
    fn divmod(&self, other: &U256) -> (U256, U256) {
        assert!(*other != U256::ZERO);
        if self < other {
            return (U256::ZERO, *self);
        }
        let mut quotient = U256::ZERO;
        let mut remainder = U256::ZERO;
        for i in (0..self.bitlen()).rev() {
            remainder = remainder.shl1();
            if self.bit(i) {
                remainder.0[0] |= 1;
            }
            if remainder >= *other {
                remainder = remainder.sub(other);
                quotient.0[i / 64] |= 1u64 << (i % 64);
            }
        }
        (quotient, remainder)
    }
}

fn isqrt(n: &U256) -> U256 {
    // Bit-by-bit square root (no multiplication needed).
    let mut rem = *n;
    let mut res = U256::ZERO;
    // largest power of four <= 2^256
    let mut bit = U256([0, 0, 0, 1u64 << 62]);
    while bit != U256::ZERO {
        let trial = res.add(&bit);
        if rem >= trial {
            rem = rem.sub(&trial);
            res = res.shr1().add(&bit);
        } else {
            res = res.shr1();
        }
        bit = bit.shr2();
    }
    res
}

fn icbrt(n: &U256) -> U256 {
    // Newton iteration from an overestimate.
    if *n == U256::ZERO {
        return U256::ZERO;
    }
    let bits = n.bitlen();
    let mut x = U256::from_u128(1).shl((bits + 2) / 3 + 1);
    loop {
        let x2 = x.mul(&x);
        let (q, _) = n.divmod(&x2);
        let two_x = x.shl1();
        let sum = two_x.add(&q);
        let (y, _) = sum.divmod(&U256::from_u128(3));
        if y >= x {
            return x;
        }
        x = y;
    }
}

fn first_primes(count: usize) -> Vec<u64> {
    let mut primes = Vec::new();
    let mut candidate = 2u64;
    while primes.len() < count {
        if (2..candidate).all(|d| candidate % d != 0) {
            primes.push(candidate);
        }
        candidate += 1;
    }
    primes
}

fn sha256_constants() -> &'static ([u32; 64], [u32; 8]) {
    static C: OnceLock<([u32; 64], [u32; 8])> = OnceLock::new();
    C.get_or_init(|| {
        let primes = first_primes(64);
        let mut k = [0u32; 64];
        for (i, &p) in primes.iter().enumerate() {
            // floor(cbrt(p) * 2^32); low 32 bits are the constant
            let n = U256::from_u128(p as u128).shl(96);
            let r = icbrt(&n);
            k[i] = r.0[0] as u32;
        }
        let mut h = [0u32; 8];
        for (i, &p) in primes[..8].iter().enumerate() {
            let n = U256::from_u128(p as u128).shl(64);
            let r = isqrt(&n);
            h[i] = r.0[0] as u32;
        }
        (k, h)
    })
}

fn sha512_constants() -> &'static ([u64; 80], [u64; 8]) {
    static C: OnceLock<([u64; 80], [u64; 8])> = OnceLock::new();
    C.get_or_init(|| {
        let primes = first_primes(80);
        let mut k = [0u64; 80];
        for (i, &p) in primes.iter().enumerate() {
            let n = U256::from_u128(p as u128).shl(192);
            let r = icbrt(&n);
            k[i] = r.0[0];
        }
        let mut h = [0u64; 8];
        for (i, &p) in primes[..8].iter().enumerate() {
            let n = U256::from_u128(p as u128).shl(128);
            let r = isqrt(&n);
            h[i] = r.0[0];
        }
        (k, h)
    })
}

// --- SHA-256 ---------------------------------------------------

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let (k, h0) = sha256_constants();
    let mut h = *h0;
    let bitlen = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    for block in msg.chunks_exact(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(block[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(k[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }
    let mut out = [0u8; 32];
    for i in 0..8 {
        out[i * 4..i * 4 + 4].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

// --- SHA-512 ---------------------------------------------------

pub fn sha512(data: &[u8]) -> [u8; 64] {
    let (k, h0) = sha512_constants();
    let mut h = *h0;
    let bitlen = (data.len() as u128) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while msg.len() % 128 != 112 {
        msg.push(0);
    }
    msg.extend_from_slice(&bitlen.to_be_bytes());
    for block in msg.chunks_exact(128) {
        let mut w = [0u64; 80];
        for i in 0..16 {
            w[i] = u64::from_be_bytes(block[i * 8..i * 8 + 8].try_into().unwrap());
        }
        for i in 16..80 {
            let s0 = w[i - 15].rotate_right(1) ^ w[i - 15].rotate_right(8) ^ (w[i - 15] >> 7);
            let s1 = w[i - 2].rotate_right(19) ^ w[i - 2].rotate_right(61) ^ (w[i - 2] >> 6);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..80 {
            let s1 = e.rotate_right(14) ^ e.rotate_right(18) ^ e.rotate_right(41);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(k[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(28) ^ a.rotate_right(34) ^ a.rotate_right(39);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }
    let mut out = [0u8; 64];
    for i in 0..8 {
        out[i * 8..i * 8 + 8].copy_from_slice(&h[i].to_be_bytes());
    }
    out
}

// --- HMAC / PBKDF2 ------------------------------------------------

fn hmac(hash: fn(&[u8]) -> Vec<u8>, block_size: usize, key: &[u8], msg: &[u8]) -> Vec<u8> {
    let mut k = if key.len() > block_size { hash(key) } else { key.to_vec() };
    k.resize(block_size, 0);
    let ipad: Vec<u8> = k.iter().map(|b| b ^ 0x36).collect();
    let opad: Vec<u8> = k.iter().map(|b| b ^ 0x5c).collect();
    let mut inner = ipad;
    inner.extend_from_slice(msg);
    let inner_hash = hash(&inner);
    let mut outer = opad;
    outer.extend_from_slice(&inner_hash);
    hash(&outer)
}

pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    hmac(|d| sha256(d).to_vec(), 64, key, msg).try_into().unwrap()
}

pub fn hmac_sha512(key: &[u8], msg: &[u8]) -> [u8; 64] {
    hmac(|d| sha512(d).to_vec(), 128, key, msg).try_into().unwrap()
}

pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32, dklen: usize) -> Vec<u8> {
    pbkdf2(|k, m| hmac_sha256(k, m).to_vec(), password, salt, iterations, dklen)
}

pub fn pbkdf2_hmac_sha512(password: &[u8], salt: &[u8], iterations: u32, dklen: usize) -> Vec<u8> {
    pbkdf2(|k, m| hmac_sha512(k, m).to_vec(), password, salt, iterations, dklen)
}

fn pbkdf2(
    prf: impl Fn(&[u8], &[u8]) -> Vec<u8>,
    password: &[u8],
    salt: &[u8],
    iterations: u32,
    dklen: usize,
) -> Vec<u8> {
    let mut out = Vec::new();
    let mut block_index = 1u32;
    while out.len() < dklen {
        let mut msg = salt.to_vec();
        msg.extend_from_slice(&block_index.to_be_bytes());
        let mut u = prf(password, &msg);
        let mut t = u.clone();
        for _ in 1..iterations {
            u = prf(password, &u);
            for i in 0..t.len() {
                t[i] ^= u[i];
            }
        }
        out.extend_from_slice(&t);
        block_index += 1;
    }
    out.truncate(dklen);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn sha256_vectors() {
        assert_eq!(
            hex(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn sha512_vectors() {
        assert_eq!(
            hex(&sha512(b"abc")),
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        );
    }
}
