//! NIST P-256 (secp256r1) from scratch: 256-bit limb arithmetic,
//! Jacobian point operations, ECDH and ECDSA over SHA-sized digests.
//! Domain parameters are the published constants of FIPS 186-4 / SEC 2.
//! Correctness is anchored by the RFC 6979 verification vector in tests
//! and by the OpenSSL DTLS handshake oracle; constant-time operation is
//! explicitly NOT claimed (test/research stack — see SPEC-WEBRTC.md).

use crate::crypto::random_bytes;

// p, n as little-endian u64 limbs.
const P: [u64; 4] = [
    0xFFFF_FFFF_FFFF_FFFF,
    0x0000_0000_FFFF_FFFF,
    0x0000_0000_0000_0000,
    0xFFFF_FFFF_0000_0001,
];
const N: [u64; 4] = [
    0xF3B9_CAC2_FC63_2551,
    0xBCE6_FAAD_A717_9E84,
    0xFFFF_FFFF_FFFF_FFFF,
    0xFFFF_FFFF_0000_0000,
];
const B: [u64; 4] = [
    0x3BCE_3C3E_27D2_604B,
    0x651D_06B0_CC53_B0F6,
    0xB3EB_BD55_7698_86BC,
    0x5AC6_35D8_AA3A_93E7,
];
const GX: [u64; 4] = [
    0xF4A1_3945_D898_C296,
    0x7703_7D81_2DEB_33A0,
    0xF8BC_E6E5_63A4_40F2,
    0x6B17_D1F2_E12C_4247,
];
type U256 = [u64; 4];

fn gy() -> U256 {
    // 4FE342E2 FE1A7F9B 8EE7EB4A 7C0F9E16 2BCE3357 6B315ECE CBB64068 37BF51F5
    [
        0xCBB6_4068_37BF_51F5,
        0x2BCE_3357_6B31_5ECE,
        0x8EE7_EB4A_7C0F_9E16,
        0x4FE3_42E2_FE1A_7F9B,
    ]
}

fn gx() -> U256 {
    GX
}

fn from_be(bytes: &[u8; 32]) -> U256 {
    let mut out = [0u64; 4];
    for i in 0..4 {
        out[3 - i] = u64::from_be_bytes(bytes[i * 8..i * 8 + 8].try_into().unwrap());
    }
    out
}

fn to_be(v: &U256) -> [u8; 32] {
    let mut out = [0u8; 32];
    for i in 0..4 {
        out[i * 8..i * 8 + 8].copy_from_slice(&v[3 - i].to_be_bytes());
    }
    out
}

fn cmp(a: &U256, b: &U256) -> core::cmp::Ordering {
    for i in (0..4).rev() {
        match a[i].cmp(&b[i]) {
            core::cmp::Ordering::Equal => continue,
            other => return other,
        }
    }
    core::cmp::Ordering::Equal
}

fn sub_raw(a: &U256, b: &U256) -> U256 {
    let mut out = [0u64; 4];
    let mut borrow = 0u64;
    for i in 0..4 {
        let (r1, b1) = a[i].overflowing_sub(b[i]);
        let (r2, b2) = r1.overflowing_sub(borrow);
        out[i] = r2;
        borrow = (b1 | b2) as u64;
    }
    out
}

fn addmod(a: &U256, b: &U256, m: &U256) -> U256 {
    let mut out = [0u64; 4];
    let mut carry = 0u128;
    for i in 0..4 {
        let s = a[i] as u128 + b[i] as u128 + carry;
        out[i] = s as u64;
        carry = s >> 64;
    }
    if carry == 1 || cmp(&out, m) != core::cmp::Ordering::Less {
        out = sub_raw(&out, m);
    }
    out
}

fn submod(a: &U256, b: &U256, m: &U256) -> U256 {
    if cmp(a, b) == core::cmp::Ordering::Less {
        let diff = sub_raw(b, a);
        sub_raw(m, &diff)
    } else {
        sub_raw(a, b)
    }
}

fn mul_wide(a: &U256, b: &U256) -> [u64; 8] {
    let mut out = [0u64; 8];
    for i in 0..4 {
        let mut carry = 0u128;
        for j in 0..4 {
            let idx = i + j;
            let cur = out[idx] as u128 + a[i] as u128 * b[j] as u128 + carry;
            out[idx] = cur as u64;
            carry = cur >> 64;
        }
        let mut idx = i + 4;
        while carry > 0 {
            let cur = out[idx] as u128 + carry;
            out[idx] = cur as u64;
            carry = cur >> 64;
            idx += 1;
        }
    }
    out
}

fn reduce_wide(wide: &[u64; 8], m: &U256) -> U256 {
    // Bitwise long division: 512 steps of shift/compare/subtract.
    let mut rem = [0u64; 5];
    let mext = [m[0], m[1], m[2], m[3], 0];
    for bit in (0..512).rev() {
        // shift rem left by 1
        let mut carry = 0u64;
        for limb in rem.iter_mut() {
            let next = *limb >> 63;
            *limb = (*limb << 1) | carry;
            carry = next;
        }
        rem[0] |= (wide[bit / 64] >> (bit % 64)) & 1;
        // if rem >= m, subtract
        let mut ge = true;
        let mut lt = false;
        for i in (0..5).rev() {
            if rem[i] < mext[i] {
                ge = false;
                lt = true;
                break;
            } else if rem[i] > mext[i] {
                break;
            }
        }
        if ge && !lt || (ge && rem == mext) {
            let mut borrow = 0u64;
            for i in 0..5 {
                let (r1, b1) = rem[i].overflowing_sub(mext[i]);
                let (r2, b2) = r1.overflowing_sub(borrow);
                rem[i] = r2;
                borrow = (b1 | b2) as u64;
            }
        }
        let _ = lt;
    }
    [rem[0], rem[1], rem[2], rem[3]]
}

fn mulmod(a: &U256, b: &U256, m: &U256) -> U256 {
    reduce_wide(&mul_wide(a, b), m)
}

fn powmod(base: &U256, exp: &U256, m: &U256) -> U256 {
    let mut result: U256 = [1, 0, 0, 0];
    let mut cur = *base;
    for i in 0..256 {
        let bit = (exp[i / 64] >> (i % 64)) & 1;
        if bit == 1 {
            result = mulmod(&result, &cur, m);
        }
        cur = mulmod(&cur, &cur, m);
    }
    result
}

fn invmod(a: &U256, m: &U256) -> U256 {
    let m_minus_2 = sub_raw(m, &[2, 0, 0, 0]);
    powmod(a, &m_minus_2, m)
}

fn is_zero(v: &U256) -> bool {
    *v == [0, 0, 0, 0]
}

// ---------------------------------------------------------------------------
// Points (Jacobian; affine at the boundary)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct PublicKey {
    pub x: [u8; 32],
    pub y: [u8; 32],
}

#[derive(Clone, Copy)]
struct Jac {
    x: U256,
    y: U256,
    z: U256, // zero = infinity
}

const INF: Jac = Jac { x: [0; 4], y: [1, 0, 0, 0], z: [0; 4] };

fn jac_from_affine(x: &U256, y: &U256) -> Jac {
    Jac { x: *x, y: *y, z: [1, 0, 0, 0] }
}

fn to_affine(p: &Jac) -> Option<(U256, U256)> {
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
    // a = -3 formulas (FIPS / hyperelliptic.org EFD dbl-2001-b)
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
        addmod(&t2, &t, &P) // 3*(X-Z^2)(X+Z^2)
    };
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

fn scalar_mul(k: &U256, point: &Jac) -> Jac {
    let mut acc = INF;
    for i in (0..256).rev() {
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

fn on_curve(x: &U256, y: &U256) -> bool {
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
    pub fn encode_uncompressed(&self) -> [u8; 65] {
        let mut out = [0u8; 65];
        out[0] = 0x04;
        out[1..33].copy_from_slice(&self.x);
        out[33..65].copy_from_slice(&self.y);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != 65 || bytes[0] != 0x04 {
            return None;
        }
        let key = Self {
            x: bytes[1..33].try_into().ok()?,
            y: bytes[33..65].try_into().ok()?,
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

    /// ECDSA verify over a 32-byte digest. `sig` is (r, s), each 32-byte BE.
    pub fn verify(&self, digest: &[u8; 32], r: &[u8; 32], s: &[u8; 32]) -> bool {
        let r_n = from_be(r);
        let s_n = from_be(s);
        if is_zero(&r_n) || is_zero(&s_n) {
            return false;
        }
        if cmp(&r_n, &N) != core::cmp::Ordering::Less || cmp(&s_n, &N) != core::cmp::Ordering::Less {
            return false;
        }
        let e = {
            let v = from_be(digest);
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

#[derive(Clone)]
pub struct PrivateKey(U256);

impl PrivateKey {
    pub fn generate() -> (Self, PublicKey) {
        loop {
            let bytes: [u8; 32] = random_bytes(32).try_into().unwrap();
            let d = from_be(&bytes);
            if is_zero(&d) || cmp(&d, &N) != core::cmp::Ordering::Less {
                continue;
            }
            let key = Self(d);
            let public = key.public_key();
            return (key, public);
        }
    }

    pub fn from_bytes(bytes: &[u8; 32]) -> Option<Self> {
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

    /// ECDH: returns the x-coordinate of d*peer, 32-byte BE.
    pub fn ecdh(&self, peer: &PublicKey) -> Option<[u8; 32]> {
        let point = scalar_mul(&self.0, &peer.to_jac());
        let (x, _) = to_affine(&point)?;
        Some(to_be(&x))
    }

    /// ECDSA sign a 32-byte digest; returns (r, s) 32-byte BE each.
    pub fn sign(&self, digest: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
        let e = {
            let v = from_be(digest);
            if cmp(&v, &N) == core::cmp::Ordering::Less {
                v
            } else {
                sub_raw(&v, &N)
            }
        };
        loop {
            let k_bytes: [u8; 32] = random_bytes(32).try_into().unwrap();
            let k = from_be(&k_bytes);
            if is_zero(&k) || cmp(&k, &N) != core::cmp::Ordering::Less {
                continue;
            }
            let (x, _) = match to_affine(&scalar_mul(&k, &generator())) {
                Some(v) => v,
                None => continue,
            };
            let r = if cmp(&x, &N) == core::cmp::Ordering::Less { x } else { sub_raw(&x, &N) };
            if is_zero(&r) {
                continue;
            }
            let k_inv = invmod(&k, &N);
            let rd = mulmod(&r, &self.0, &N);
            let s = mulmod(&k_inv, &addmod(&e, &rd, &N), &N);
            if is_zero(&s) {
                continue;
            }
            return (to_be(&r), to_be(&s));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::sha256;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn generator_on_curve() {
        assert!(on_curve(&gx(), &gy()));
    }

    #[test]
    fn ecdh_agrees() {
        let (a, a_pub) = PrivateKey::generate();
        let (b, b_pub) = PrivateKey::generate();
        assert_eq!(a.ecdh(&b_pub).unwrap(), b.ecdh(&a_pub).unwrap());
    }

    #[test]
    fn ecdsa_roundtrip() {
        let (key, public) = PrivateKey::generate();
        let digest = sha256(b"hello dtls");
        let (r, s) = key.sign(&digest);
        assert!(public.verify(&digest, &r, &s));
        let other = sha256(b"different");
        assert!(!public.verify(&other, &r, &s));
    }

    #[test]
    fn external_verify_vector() {
        // Public key of RFC 6979's P-256 test key; signature over
        // "sample" (SHA-256, raw r||s) produced by Node's crypto —
        // an independent implementation, so this anchors our verify
        // (and, via roundtrip tests, our arithmetic) externally.
        let public = PublicKey {
            x: unhex("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6")
                .try_into()
                .unwrap(),
            y: unhex("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")
                .try_into()
                .unwrap(),
        };
        assert!(PublicKey::decode(&public.encode_uncompressed()).is_some());
        let digest = sha256(b"sample");
        let r: [u8; 32] = unhex("453B5502F4584364E40022EB01A96EF0B8B792C746D170F9CA2766F0E0ECB40F")
            .try_into()
            .unwrap();
        let s: [u8; 32] = unhex("C33A922A541AAAA349276F3C920EF05D684B461C9C6593D5EB6EE06A94F30595")
            .try_into()
            .unwrap();
        assert!(public.verify(&digest, &r, &s));
    }
}
