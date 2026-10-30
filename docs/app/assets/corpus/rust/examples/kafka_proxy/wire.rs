//! Kafka wire primitives: big-endian scalars, flexible
//! (compact) encodings, zigzag varints, CRC32C. Dependency-free.

#[derive(Clone)]
pub struct W(pub Vec<u8>);

impl W {
    pub fn new() -> Self {
        W(Vec::new())
    }
    pub fn i8(&mut self, v: i8) {
        self.0.push(v as u8);
    }
    pub fn i16(&mut self, v: i16) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    pub fn i32(&mut self, v: i32) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    pub fn i64(&mut self, v: i64) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    pub fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_be_bytes());
    }
    pub fn bytes(&mut self, b: &[u8]) {
        self.0.extend_from_slice(b);
    }
    /// Unsigned varint (flexible-version length prefixes).
    pub fn uvarint(&mut self, mut v: u64) {
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                self.0.push(b);
                break;
            }
            self.0.push(b | 0x80);
        }
    }
    /// Zigzag varint (record bodies).
    pub fn varint(&mut self, v: i64) {
        self.uvarint(((v << 1) ^ (v >> 63)) as u64);
    }
    pub fn varlong(&mut self, v: i64) {
        self.varint(v);
    }
    /// Compact string (flexible versions).
    pub fn cstr(&mut self, s: &str) {
        self.uvarint(s.len() as u64 + 1);
        self.bytes(s.as_bytes());
    }
    pub fn cstr_opt(&mut self, s: Option<&str>) {
        match s {
            Some(s) => self.cstr(s),
            None => self.uvarint(0),
        }
    }
    /// Compact bytes.
    pub fn cbytes(&mut self, b: &[u8]) {
        self.uvarint(b.len() as u64 + 1);
        self.bytes(b);
    }
    pub fn cbytes_opt(&mut self, b: Option<&[u8]>) {
        match b {
            Some(b) => self.cbytes(b),
            None => self.uvarint(0),
        }
    }
    /// Compact array length prefix. Callers write elements.
    pub fn carr(&mut self, n: usize) {
        self.uvarint(n as u64 + 1);
    }
    /// Plain (non-flexible) string / bytes.
    pub fn str16(&mut self, s: &str) {
        self.i16(s.len() as i16);
        self.bytes(s.as_bytes());
    }
    pub fn str16_opt(&mut self, s: Option<&str>) {
        match s {
            Some(s) => self.str16(s),
            None => self.i16(-1),
        }
    }
    pub fn bytes32(&mut self, b: &[u8]) {
        self.i32(b.len() as i32);
        self.bytes(b);
    }
    pub fn arr32(&mut self, n: usize) {
        self.i32(n as i32);
    }
    /// Empty tagged-fields section (flexible versions).
    pub fn tagged_none(&mut self) {
        self.uvarint(0);
    }
}

pub struct R<'a> {
    pub buf: &'a [u8],
    pub pos: usize,
}

impl<'a> R<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        R { buf, pos: 0 }
    }
    pub fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }
    pub fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        if self.remaining() < n {
            return Err("kafka: short buffer".into());
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    pub fn i8(&mut self) -> Result<i8, String> {
        Ok(self.take(1)?[0] as i8)
    }
    pub fn i16(&mut self) -> Result<i16, String> {
        Ok(i16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    pub fn i32(&mut self) -> Result<i32, String> {
        Ok(i32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    pub fn i64(&mut self) -> Result<i64, String> {
        Ok(i64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
    pub fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    pub fn uvarint(&mut self) -> Result<u64, String> {
        let mut result: u64 = 0;
        let mut shift = 0;
        loop {
            let b = self.take(1)?[0];
            result |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                break;
            }
            shift += 7;
            if shift > 63 {
                return Err("kafka: varint too long".into());
            }
        }
        Ok(result)
    }
    pub fn varint(&mut self) -> Result<i64, String> {
        let v = self.uvarint()?;
        Ok(((v >> 1) as i64) ^ -((v & 1) as i64))
    }
    pub fn cstr(&mut self) -> Result<String, String> {
        let n = self.uvarint()?;
        if n == 0 {
            return Err("kafka: null compact string".into());
        }
        let b = self.take((n - 1) as usize)?;
        String::from_utf8(b.to_vec()).map_err(|_| "kafka: bad utf8".to_string())
    }
    pub fn cstr_opt(&mut self) -> Result<Option<String>, String> {
        let n = self.uvarint()?;
        if n == 0 {
            return Ok(None);
        }
        let b = self.take((n - 1) as usize)?;
        String::from_utf8(b.to_vec()).map(Some).map_err(|_| "kafka: bad utf8".to_string())
    }
    pub fn cbytes(&mut self) -> Result<Vec<u8>, String> {
        let n = self.uvarint()?;
        if n == 0 {
            return Err("kafka: null compact bytes".into());
        }
        Ok(self.take((n - 1) as usize)?.to_vec())
    }
    pub fn cbytes_opt(&mut self) -> Result<Option<Vec<u8>>, String> {
        let n = self.uvarint()?;
        if n == 0 {
            return Ok(None);
        }
        Ok(Some(self.take((n - 1) as usize)?.to_vec()))
    }
    /// Compact array count; -1 encoded as 0 maps to None.
    pub fn carr(&mut self) -> Result<Option<usize>, String> {
        let n = self.uvarint()?;
        if n == 0 {
            Ok(None)
        } else {
            Ok(Some((n - 1) as usize))
        }
    }
    pub fn carr_len(&mut self) -> Result<usize, String> {
        Ok(self.carr()?.unwrap_or(0))
    }
    pub fn str16(&mut self) -> Result<String, String> {
        let n = self.i16()?;
        if n < 0 {
            return Err("kafka: null string".into());
        }
        let b = self.take(n as usize)?;
        String::from_utf8(b.to_vec()).map_err(|_| "kafka: bad utf8".to_string())
    }
    pub fn str16_opt(&mut self) -> Result<Option<String>, String> {
        let n = self.i16()?;
        if n < 0 {
            return Ok(None);
        }
        let b = self.take(n as usize)?;
        String::from_utf8(b.to_vec()).map(Some).map_err(|_| "kafka: bad utf8".to_string())
    }
    pub fn bytes32(&mut self) -> Result<Vec<u8>, String> {
        let n = self.i32()?;
        if n < 0 {
            return Ok(Vec::new());
        }
        Ok(self.take(n as usize)?.to_vec())
    }
    pub fn bytes32_opt(&mut self) -> Result<Option<Vec<u8>>, String> {
        let n = self.i32()?;
        if n < 0 {
            return Ok(None);
        }
        Ok(Some(self.take(n as usize)?.to_vec()))
    }
    pub fn arr32(&mut self) -> Result<i32, String> {
        self.i32()
    }
    /// Skip a tagged-fields section (flexible versions).
    pub fn skip_tagged(&mut self) -> Result<(), String> {
        let count = self.uvarint()?;
        for _ in 0..count {
            let _tag = self.uvarint()?;
            let size = self.uvarint()?;
            self.take(size as usize)?;
        }
        Ok(())
    }
}

// CRC-32C (Castagnoli), table-driven — used by record batches.
const fn build_crc32c_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut j = 0;
        while j < 8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0x82f63b78 } else { crc >> 1 };
            j += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

static CRC32C_TABLE: [u32; 256] = build_crc32c_table();

pub fn crc32c(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &b in data {
        crc = CRC32C_TABLE[((crc ^ b as u32) & 0xff) as usize] ^ (crc >> 8);
    }
    crc ^ 0xffff_ffff
}
