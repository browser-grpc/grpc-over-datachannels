//! NIST P-384 (secp384r1) ECDSA verification from scratch,
//! mirroring p256.rs (same generic long-division field
//! arithmetic at 384-bit width; verify-only — certificate
//! chains for tls12.rs). Domain parameters are the published
//! constants of FIPS 186-4 / SEC 2. Correctness is anchored
//! by the OpenSSL-produced signature in tests; constant-time
//! operation is explicitly NOT claimed.

// p, n as little-endian u64 limbs.
const P: [u64; 6] = [
    0x00000000FFFFFFFF,
    0xFFFFFFFF00000000,
    0xFFFFFFFFFFFFFFFE,
    0xFFFFFFFFFFFFFFFF,
    0xFFFFFFFFFFFFFFFF,
    0xFFFFFFFFFFFFFFFF,
];
const N: [u64; 6] = [
    0xECEC196ACCC52973,
    0x581A0DB248B0A77A,
    0xC7634D81F4372DDF,
    0xFFFFFFFFFFFFFFFF,
    0xFFFFFFFFFFFFFFFF,
    0xFFFFFFFFFFFFFFFF,
];
const B: [u64; 6] = [
    0x2A85C8EDD3EC2AEF,
    0xC656398D8A2ED19D,
    0x0314088F5013875A,
    0x181D9C6EFE814112,
    0x988E056BE3F82D19,
    0xB3312FA7E23EE7E4,
];
const GX: [u64; 6] = [
    0x3A545E3872760AB7,
    0x5502F25DBF55296C,
    0x59F741E082542A38,
    0x6E1D3B628BA79B98,
    0x8EB1C71EF320AD74,
    0xAA87CA22BE8B0537,
];
type U384 = [u64; 6];

fn gy() -> U384 {
    [
        0x7A431D7C90EA0E5F,
        0x0A60B1CE1D7E819D,
        0xE9DA3113B5F0B8C0,
        0xF8F41DBD289A147C,
        0x5D9E98BF9292DC29,
        0x3617DE4A96262C6F,
    ]
}

fn gx() -> U384 {
    GX
}

fn from_be(bytes: &[u8; 48]) -> U384 {
    let mut out = [0u64; 6];
    for i in 0..6 {
        out[5 - i] = u64::from_be_bytes(bytes[i * 8..i * 8 + 8].try_into().unwrap());
    }
    out
}

fn cmp(a: &U384, b: &U384) -> core::cmp::Ordering {
    for i in (0..6).rev() {
        match a[i].cmp(&b[i]) {
            core::cmp::Ordering::Equal => continue,
            other => return other,
        }
    }
    core::cmp::Ordering::Equal
}

fn sub_raw(a: &U384, b: &U384) -> U384 {
    let mut out = [0u64; 6];
    let mut borrow = 0u64;
    for i in 0..6 {
        let (r1, b1) = a[i].overflowing_sub(b[i]);
        let (r2, b2) = r1.overflowing_sub(borrow);
        out[i] = r2;
        borrow = (b1 | b2) as u64;
    }
    out
}

fn addmod(a: &U384, b: &U384, m: &U384) -> U384 {
    let mut out = [0u64; 6];
    let mut carry = 0u128;
    for i in 0..6 {
        let s = a[i] as u128 + b[i] as u128 + carry;
        out[i] = s as u64;
        carry = s >> 64;
    }
    if carry == 1 || cmp(&out, m) != core::cmp::Ordering::Less {
        out = sub_raw(&out, m);
    }
    out
}

fn submod(a: &U384, b: &U384, m: &U384) -> U384 {
    if cmp(a, b) == core::cmp::Ordering::Less {
        let diff = sub_raw(b, a);
        sub_raw(m, &diff)
    } else {
        sub_raw(a, b)
    }
}

fn mul_wide(a: &U384, b: &U384) -> [u64; 12] {
    let mut out = [0u64; 12];
    for i in 0..6 {
        let mut carry = 0u128;
        for j in 0..6 {
            let idx = i + j;
            let cur = out[idx] as u128 + a[i] as u128 * b[j] as u128 + carry;
            out[idx] = cur as u64;
            carry = cur >> 64;
        }
        let mut idx = i + 6;
        while carry > 0 {
            let cur = out[idx] as u128 + carry;
            out[idx] = cur as u64;
            carry = cur >> 64;
            idx += 1;
        }
    }
    out
}

fn reduce_wide(wide: &[u64; 12], m: &U384) -> U384 {
    // Bitwise long division: 768 steps of shift/compare/subtract.
    let mut rem = [0u64; 7];
    let mext = [m[0], m[1], m[2], m[3], m[4], m[5], 0];
    for bit in (0..768).rev() {
        let mut carry = 0u64;
        for limb in rem.iter_mut() {
            let next = *limb >> 63;
            *limb = (*limb << 1) | carry;
            carry = next;
        }
        rem[0] |= (wide[bit / 64] >> (bit % 64)) & 1;
        let mut ge = true;
        for i in (0..7).rev() {
            if rem[i] < mext[i] {
                ge = false;
                break;
            } else if rem[i] > mext[i] {
                break;
            }
        }
        if ge {
            let mut borrow = 0u64;
            for i in 0..7 {
                let (r1, b1) = rem[i].overflowing_sub(mext[i]);
                let (r2, b2) = r1.overflowing_sub(borrow);
                rem[i] = r2;
                borrow = (b1 | b2) as u64;
            }
        }
    }
    [rem[0], rem[1], rem[2], rem[3], rem[4], rem[5]]
}

fn mulmod(a: &U384, b: &U384, m: &U384) -> U384 {
    reduce_wide(&mul_wide(a, b), m)
}

fn powmod(base: &U384, exp: &U384, m: &U384) -> U384 {
    let mut result: U384 = [1, 0, 0, 0, 0, 0];
    let mut cur = *base;
    for i in 0..384 {
        let bit = (exp[i / 64] >> (i % 64)) & 1;
        if bit == 1 {
            result = mulmod(&result, &cur, m);
        }
        cur = mulmod(&cur, &cur, m);
    }
    result
}

fn invmod(a: &U384, m: &U384) -> U384 {
    let m_minus_2 = sub_raw(m, &[2, 0, 0, 0, 0, 0]);
    powmod(a, &m_minus_2, m)
}

fn is_zero(v: &U384) -> bool {
    *v == [0; 6]
}

fn to_be(v: &U384) -> [u8; 48] {
    let mut out = [0u8; 48];
    for i in 0..6 {
        out[i * 8..i * 8 + 8].copy_from_slice(&v[5 - i].to_be_bytes());
    }
    out
}

// ---------------------------------------------------------------------------
// Points (Jacobian; affine at the boundary)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct PublicKey {
    pub x: [u8; 48],
    pub y: [u8; 48],
}

#[derive(Clone, Copy)]
struct Jac {
    x: U384,
    y: U384,
    z: U384, // zero = infinity
}

const INF: Jac = Jac { x: [0; 6], y: [1, 0, 0, 0, 0, 0], z: [0; 6] };

fn jac_from_affine(x: &U384, y: &U384) -> Jac {
    Jac { x: *x, y: *y, z: [1, 0, 0, 0, 0, 0] }
}

fn to_affine(p: &Jac) -> Option<(U384, U384)> {
    if is_zero(&p.z) {
        return None;
    }
    let zinv = invmod(&p.z, &P);
    let zinv2 = mulmod(&zinv, &zinv, &P);
    let zinv3 = mulmod(&zinv2, &zinv, &P);
    Some((mulmod(&p.x, &zinv2, &P), mulmod(&p.y, &zinv3, &P)))
}

fn jac_double(p: &Jac) -> Jac {
    if is_zero(&p.z) || is_zero(&p.y) {
        return INF;
    }
    let xx = mulmod(&p.x, &p.x, &P);
    let yy = mulmod(&p.y, &p.y, &P);
    let yyyy = mulmod(&yy, &yy, &P);
    let zz = mulmod(&p.z, &p.z, &P);
    let s = {
        let t = mulmod(&p.x, &yy, &P);
        let two = addmod(&t, &t, &P);
        addmod(&two, &two, &P)
    };
    let m = {
        let x_minus_zz = submod(&p.x, &zz, &P);
        let x_plus_zz = addmod(&p.x, &zz, &P);
        let t = mulmod(&x_minus_zz, &x_plus_zz, &P);
        let t2 = addmod(&t, &t, &P);
        addmod(&t2, &t, &P)
    };
    let _ = xx;
    let x3 = {
        let m2 = mulmod(&m, &m, &P);
        let s2 = addmod(&s, &s, &P);
        submod(&m2, &s2, &P)
    };
    let y3 = {
        let m_s_min_x = mulmod(&m, &submod(&s, &x3, &P), &P);
        let eight_yyyy = {
            let t = addmod(&yyyy, &yyyy, &P);
            let t = addmod(&t, &t, &P);
            addmod(&t, &t, &P)
        };
        submod(&m_s_min_x, &eight_yyyy, &P)
    };
    let z3 = {
        let yz = addmod(&p.y, &p.z, &P);
        let yz2 = mulmod(&yz, &yz, &P);
        submod(&submod(&yz2, &yy, &P), &zz, &P)
    };
    Jac { x: x3, y: y3, z: z3 }
}

fn jac_add(p: &Jac, q: &Jac) -> Jac {
    if is_zero(&p.z) {
        return *q;
    }
    if is_zero(&q.z) {
        return *p;
    }
    let z1z1 = mulmod(&p.z, &p.z, &P);
    let z2z2 = mulmod(&q.z, &q.z, &P);
    let u1 = mulmod(&p.x, &z2z2, &P);
    let u2 = mulmod(&q.x, &z1z1, &P);
    let s1 = {
        let t = mulmod(&p.y, &q.z, &P);
        mulmod(&t, &z2z2, &P)
    };
    let s2 = {
        let t = mulmod(&q.y, &p.z, &P);
        mulmod(&t, &z1z1, &P)
    };
    if u1 == u2 {
        if s1 != s2 {
            return INF;
        }
        return jac_double(p);
    }
    let h = submod(&u2, &u1, &P);
    let two_h = addmod(&h, &h, &P);
    let i = mulmod(&two_h, &two_h, &P);
    let j = mulmod(&h, &i, &P);
    let r = {
        let d = submod(&s2, &s1, &P);
        addmod(&d, &d, &P)
    };
    let v = mulmod(&u1, &i, &P);
    let x3 = {
        let r2 = mulmod(&r, &r, &P);
        let v2 = addmod(&v, &v, &P);
        submod(&submod(&r2, &j, &P), &v2, &P)
    };
    let y3 = {
        let a = mulmod(&r, &submod(&v, &x3, &P), &P);
        let b = {
            let t = mulmod(&s1, &j, &P);
            addmod(&t, &t, &P)
        };
        submod(&a, &b, &P)
    };
    let z3 = {
        let zsum = addmod(&p.z, &q.z, &P);
        let zsum2 = mulmod(&zsum, &zsum, &P);
        let zz = submod(&submod(&zsum2, &z1z1, &P), &z2z2, &P);
        mulmod(&zz, &h, &P)
    };
    Jac { x: x3, y: y3, z: z3 }
}

fn scalar_mul(k: &U384, point: &Jac) -> Jac {
    let mut acc = INF;
    for i in (0..384).rev() {
        acc = jac_double(&acc);
        let bit = (k[i / 64] >> (i % 64)) & 1;
        if bit == 1 {
            acc = jac_add(&acc, point);
        }
    }
    acc
}

fn generator() -> Jac {
    jac_from_affine(&gx(), &gy())
}

fn on_curve(x: &U384, y: &U384) -> bool {
    // y^2 == x^3 - 3x + b (mod p)
    let lhs = mulmod(y, y, &P);
    let x2 = mulmod(x, x, &P);
    let x3 = mulmod(&x2, x, &P);
    let three_x = {
        let t = addmod(x, x, &P);
        addmod(&t, x, &P)
    };
    let rhs = addmod(&submod(&x3, &three_x, &P), &B, &P);
    lhs == rhs
}

impl PublicKey {
    pub fn encode_uncompressed(&self) -> [u8; 97] {
        let mut out = [0u8; 97];
        out[0] = 0x04;
        out[1..49].copy_from_slice(&self.x);
        out[49..97].copy_from_slice(&self.y);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != 97 || bytes[0] != 0x04 {
            return None;
        }
        let key = Self {
            x: bytes[1..49].try_into().ok()?,
            y: bytes[49..97].try_into().ok()?,
        };
        let x = from_be(&key.x);
        let y = from_be(&key.y);
        if cmp(&x, &P) != core::cmp::Ordering::Less || cmp(&y, &P) != core::cmp::Ordering::Less {
            return None;
        }
        if !on_curve(&x, &y) {
            return None;
        }
        Some(key)
    }

    fn to_jac(&self) -> Jac {
        jac_from_affine(&from_be(&self.x), &from_be(&self.y))
    }

    /// ECDSA verify. `digest` is the full hash output; per
    /// FIPS 186 its leftmost 384 bits are used (fewer when the
    /// hash is shorter, e.g. SHA-256 over a P-384 key in
    /// TLS 1.2). `r`/`s` are 48-byte BE.
    pub fn verify(&self, digest: &[u8], r: &[u8; 48], s: &[u8; 48]) -> bool {
        let r_n = from_be(r);
        let s_n = from_be(s);
        if is_zero(&r_n) || is_zero(&s_n) {
            return false;
        }
        if cmp(&r_n, &N) != core::cmp::Ordering::Less || cmp(&s_n, &N) != core::cmp::Ordering::Less {
            return false;
        }
        if digest.is_empty() {
            return false;
        }
        let mut e_bytes = [0u8; 48];
        let take = digest.len().min(48);
        e_bytes[48 - take..].copy_from_slice(&digest[..take]);
        let e = {
            let v = from_be(&e_bytes);
            if cmp(&v, &N) == core::cmp::Ordering::Less {
                v
            } else {
                sub_raw(&v, &N)
            }
        };
        let w = invmod(&s_n, &N);
        let u1 = mulmod(&e, &w, &N);
        let u2 = mulmod(&r_n, &w, &N);
        let point = jac_add(&scalar_mul(&u1, &generator()), &scalar_mul(&u2, &self.to_jac()));
        match to_affine(&point) {
            Some((x, _)) => {
                let v = if cmp(&x, &N) == core::cmp::Ordering::Less {
                    x
                } else {
                    sub_raw(&x, &N)
                };
                v == r_n
            }
            None => false,
        }
    }
}

pub struct PrivateKey(U384);

impl PrivateKey {
    pub fn generate() -> (Self, PublicKey) {
        loop {
            let bytes: [u8; 48] = crate::crypto::random_bytes(48).try_into().unwrap();
            let d = from_be(&bytes);
            if is_zero(&d) || cmp(&d, &N) != core::cmp::Ordering::Less {
                continue;
            }
            let key = Self(d);
            let public = key.public_key();
            return (key, public);
        }
    }

    pub fn from_bytes(bytes: &[u8; 48]) -> Option<Self> {
        let d = from_be(bytes);
        if is_zero(&d) || cmp(&d, &N) != core::cmp::Ordering::Less {
            return None;
        }
        Some(Self(d))
    }

    pub fn public_key(&self) -> PublicKey {
        let (x, y) = to_affine(&scalar_mul(&self.0, &generator())).expect("d*G not infinity");
        PublicKey { x: to_be(&x), y: to_be(&y) }
    }

    /// ECDH: returns the x-coordinate of d*peer, 48-byte BE.
    pub fn ecdh(&self, peer: &PublicKey) -> Option<[u8; 48]> {
        let point = scalar_mul(&self.0, &peer.to_jac());
        let (x, _) = to_affine(&point)?;
        Some(to_be(&x))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::sha384;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn ecdh_agrees_both_ways() {
        let (a_secret, a_public) = PrivateKey::generate();
        let (b_secret, b_public) = PrivateKey::generate();
        assert_eq!(a_secret.ecdh(&b_public), b_secret.ecdh(&a_public));
        assert!(PublicKey::decode(&a_public.encode_uncompressed()).is_some());
    }

    #[test]
    fn generator_on_curve() {
        assert!(on_curve(&gx(), &gy()));
    }

    #[test]
    fn external_verify_vector() {
        // Signature over "sample" (SHA-384) produced by OpenSSL
        // with a fresh secp384r1 key — an independent
        // implementation anchoring our arithmetic externally.
        let public = PublicKey {
            x: unhex("348AAB618CCCAF8EC71522702690273C4B236012F43B65F55368E2799E3C0EA33C1C9FEC413D0AA5EA8BFA251CAAC742")
                .try_into()
                .unwrap(),
            y: unhex("7ECE736729CD089279025C27C2D8099801E9869F03EE227B19D9B418E93D4B29135DABADC3B80BAA84AB786C911688DB")
                .try_into()
                .unwrap(),
        };
        assert!(PublicKey::decode(&public.encode_uncompressed()).is_some());
        let digest = sha384(b"sample");
        let r: [u8; 48] = unhex("66C3244A9D20BC2258772CDF1CE1EE5D1D8B4A568E5F200DC9EC5E9CB233F47A2A9061D33D9EF24BB3FEA1C9E7AA8BF5")
            .try_into()
            .unwrap();
        let s: [u8; 48] = unhex("69B174FD12063920A67E43DDE6830A3FB25699124EEA1024E92BCC8596BB1A4416341D77772EAE47001522005C2D3C12")
            .try_into()
            .unwrap();
        assert!(public.verify(&digest, &r, &s));
        let other = sha384(b"different");
        assert!(!public.verify(&other, &r, &s));
    }
}
