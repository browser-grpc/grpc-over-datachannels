//! Record-batch compression codecs used by the Kafka
//! protocol: gzip (RFC1952 + DEFLATE), snappy (raw block
//! format), LZ4 (frame format). Dependency-free; compressors
//! favour correctness over ratio. Zstd compression emits raw
//! blocks in a standard frame; the decoder handles raw, RLE,
//! and compressed (Huffman literals + FSE sequences) blocks.

pub fn compress(codec: u8, data: &[u8]) -> Result<Vec<u8>, String> {
    match codec {
        0 => Ok(data.to_vec()),
        1 => Ok(gzip_compress(data)),
        2 => Ok(snappy_compress(data)),
        3 => Ok(lz4_frame_compress(data)),
        4 => Ok(zstd_compress(data)),
        c => Err(format!("kafka: unknown compression codec {c}")),
    }
}

pub fn decompress(codec: u8, data: &[u8]) -> Result<Vec<u8>, String> {
    match codec {
        0 => Ok(data.to_vec()),
        1 => gzip_decompress(data),
        2 => snappy_decompress(data),
        3 => lz4_frame_decompress(data),
        4 => zstd_decompress(data),
        c => Err(format!("kafka: unknown compression codec {c}")),
    }
}

// --- CRC-32 (IEEE, gzip trailer) -------------------------------

fn crc32_ieee(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for i in 0..256u32 {
        let mut c = i;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xedb88320 ^ (c >> 1) } else { c >> 1 };
        }
        table[i as usize] = c;
    }
    let mut crc = 0xffff_ffffu32;
    for &b in data {
        crc = table[((crc ^ b as u32) & 0xff) as usize] ^ (crc >> 8);
    }
    crc ^ 0xffff_ffff
}

// --- DEFLATE -----------------------------------------------------

struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
    bits: u32,
    nbits: usize,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        BitReader { data, pos: 0, bits: 0, nbits: 0 }
    }
    fn bit(&mut self) -> Result<u32, String> {
        if self.nbits == 0 {
            if self.pos >= self.data.len() {
                return Err("deflate: out of input".into());
            }
            self.bits = self.data[self.pos] as u32;
            self.pos += 1;
            self.nbits = 8;
        }
        let b = self.bits & 1;
        self.bits >>= 1;
        self.nbits -= 1;
        Ok(b)
    }
    fn take(&mut self, n: usize) -> Result<u32, String> {
        let mut v = 0u32;
        for i in 0..n {
            v |= self.bit()? << i;
        }
        Ok(v)
    }
    fn align_byte(&mut self) {
        self.nbits = 0;
        self.bits = 0;
    }
    fn byte(&mut self) -> Result<u8, String> {
        self.align_byte();
        if self.pos >= self.data.len() {
            return Err("deflate: out of input".into());
        }
        let b = self.data[self.pos];
        self.pos += 1;
        Ok(b)
    }
    fn bytes(&mut self, n: usize) -> Result<Vec<u8>, String> {
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            out.push(self.byte()?);
        }
        Ok(out)
    }
}

struct Huffman {
    // canonical decode: counts per code length + sorted symbols
    counts: [u16; 16],
    symbols: Vec<u16>,
}

impl Huffman {
    fn new(lengths: &[u8]) -> Huffman {
        let mut counts = [0u16; 16];
        for &l in lengths {
            counts[l as usize] += 1;
        }
        counts[0] = 0;
        let mut offsets = [0u16; 16];
        for i in 1..16 {
            offsets[i] = offsets[i - 1] + counts[i - 1];
        }
        let mut symbols = vec![0u16; lengths.iter().filter(|&&l| l > 0).count()];
        for (sym, &l) in lengths.iter().enumerate() {
            if l > 0 {
                symbols[offsets[l as usize] as usize] = sym as u16;
                offsets[l as usize] += 1;
            }
        }
        Huffman { counts, symbols }
    }
    fn decode(&self, br: &mut BitReader) -> Result<u16, String> {
        let mut code: i32 = 0;
        let mut first: i32 = 0;
        let mut index: i32 = 0;
        for len in 1..16 {
            code |= br.bit()? as i32;
            let count = self.counts[len] as i32;
            if code - count < first {
                return Ok(self.symbols[(index + (code - first)) as usize]);
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        Err("deflate: bad huffman code".into())
    }
}

const LENGTH_BASE: [usize; 29] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
    163, 195, 227, 258,
];
const LENGTH_EXTRA: [usize; 29] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
];
const DIST_BASE: [usize; 30] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
    2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
];
const DIST_EXTRA: [usize; 30] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
];

fn inflate(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut br = BitReader::new(data);
    let mut out: Vec<u8> = Vec::new();
    loop {
        let bfinal = br.bit()?;
        let btype = br.take(2)?;
        match btype {
            0 => {
                let raw = br.bytes(4)?;
                let len = u16::from_le_bytes([raw[0], raw[1]]) as usize;
                out.extend_from_slice(&br.bytes(len)?);
            }
            1 | 2 => {
                let (lit, dist) = if btype == 1 {
                    let mut lit_lengths = [0u8; 288];
                    for i in 0..144 {
                        lit_lengths[i] = 8;
                    }
                    for i in 144..256 {
                        lit_lengths[i] = 9;
                    }
                    for i in 256..280 {
                        lit_lengths[i] = 7;
                    }
                    for i in 280..288 {
                        lit_lengths[i] = 8;
                    }
                    (Huffman::new(&lit_lengths), Huffman::new(&[5u8; 30]))
                } else {
                    let hlit = br.take(5)? as usize + 257;
                    let hdist = br.take(5)? as usize + 1;
                    let hclen = br.take(4)? as usize + 4;
                    const ORDER: [usize; 19] = [
                        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                    ];
                    let mut code_lengths = [0u8; 19];
                    for i in 0..hclen {
                        code_lengths[ORDER[i]] = br.take(3)? as u8;
                    }
                    let code_huff = Huffman::new(&code_lengths);
                    let mut lengths = vec![0u8; hlit + hdist];
                    let mut i = 0;
                    while i < lengths.len() {
                        let sym = code_huff.decode(&mut br)?;
                        match sym {
                            0..=15 => {
                                lengths[i] = sym as u8;
                                i += 1;
                            }
                            16 => {
                                if i == 0 {
                                    return Err("deflate: repeat with no previous".into());
                                }
                                let prev = lengths[i - 1];
                                let rep = 3 + br.take(2)? as usize;
                                for _ in 0..rep {
                                    lengths[i] = prev;
                                    i += 1;
                                }
                            }
                            17 => {
                                let rep = 3 + br.take(3)? as usize;
                                i += rep;
                            }
                            18 => {
                                let rep = 11 + br.take(7)? as usize;
                                i += rep;
                            }
                            _ => return Err("deflate: bad length symbol".into()),
                        }
                    }
                    if lengths.len() < hlit + hdist {
                        return Err("deflate: short lengths".into());
                    }
                    (
                        Huffman::new(&lengths[..hlit]),
                        Huffman::new(&lengths[hlit..hlit + hdist]),
                    )
                };
                loop {
                    let sym = lit.decode(&mut br)?;
                    match sym {
                        0..=255 => out.push(sym as u8),
                        256 => break,
                        257..=285 => {
                            let li = (sym - 257) as usize;
                            let len = LENGTH_BASE[li] + br.take(LENGTH_EXTRA[li])? as usize;
                            let dsym = dist.decode(&mut br)? as usize;
                            if dsym >= 30 {
                                return Err("deflate: bad distance symbol".into());
                            }
                            let d = DIST_BASE[dsym] + br.take(DIST_EXTRA[dsym])? as usize;
                            if d > out.len() {
                                return Err("deflate: distance too far".into());
                            }
                            let start = out.len() - d;
                            for k in 0..len {
                                let b = out[start + k];
                                out.push(b);
                            }
                        }
                        _ => return Err("deflate: bad literal symbol".into()),
                    }
                }
            }
            _ => return Err("deflate: reserved block type".into()),
        }
        if bfinal == 1 {
            break;
        }
    }
    Ok(out)
}

fn deflate_stored(data: &[u8]) -> Vec<u8> {
    // Stored blocks only (valid DEFLATE; no ratio, no table risk).
    let mut out = Vec::new();
    if data.is_empty() {
        out.extend_from_slice(&[1, 0, 0, 0xff, 0xff]);
        return out;
    }
    let mut chunks = data.chunks(65535).peekable();
    while let Some(chunk) = chunks.next() {
        let last = chunks.peek().is_none();
        out.push(if last { 1 } else { 0 });
        let len = chunk.len() as u16;
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&(!len).to_le_bytes());
        out.extend_from_slice(chunk);
    }
    out
}

// --- gzip ----------------------------------------------------------

pub fn gzip_compress(data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff];
    out.extend_from_slice(&deflate_stored(data));
    out.extend_from_slice(&crc32_ieee(data).to_le_bytes());
    out.extend_from_slice(&(data.len() as u32).to_le_bytes());
    out
}

pub fn gzip_decompress(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 18 || data[0] != 0x1f || data[1] != 0x8b || data[2] != 8 {
        return Err("gzip: bad header".into());
    }
    let flg = data[3];
    let mut pos = 10;
    if flg & 0x04 != 0 {
        if pos + 2 > data.len() {
            return Err("gzip: short".into());
        }
        let xlen = u16::from_le_bytes([data[pos], data[pos + 1]]) as usize;
        pos += 2 + xlen;
    }
    if flg & 0x08 != 0 {
        while pos < data.len() && data[pos] != 0 {
            pos += 1;
        }
        pos += 1;
    }
    if flg & 0x10 != 0 {
        while pos < data.len() && data[pos] != 0 {
            pos += 1;
        }
        pos += 1;
    }
    if flg & 0x02 != 0 {
        pos += 2;
    }
    if pos > data.len() {
        return Err("gzip: short".into());
    }
    inflate(&data[pos..])
}

// --- snappy (raw block format) -------------------------------------

pub fn snappy_compress(data: &[u8]) -> Vec<u8> {
    // One literal run: valid, uncompressed-ratio snappy.
    let mut out = Vec::new();
    let mut n = data.len();
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
    let mut rest = data;
    while !rest.is_empty() {
        let chunk = rest.len().min(65536);
        let part = &rest[..chunk];
        let l = chunk - 1;
        if l < 60 {
            out.push((l as u8) << 2);
        } else if l < 256 {
            out.push(60 << 2);
            out.push(l as u8);
        } else {
            out.push(61 << 2);
            out.extend_from_slice(&(l as u16).to_le_bytes());
        }
        out.extend_from_slice(part);
        rest = &rest[chunk..];
    }
    out
}

pub fn snappy_decompress(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut pos = 0;
    let mut len: usize = 0;
    let mut shift = 0;
    loop {
        if pos >= data.len() {
            return Err("snappy: bad preamble".into());
        }
        let b = data[pos];
        pos += 1;
        len |= ((b & 0x7f) as usize) << shift;
        if b & 0x80 == 0 {
            break;
        }
        shift += 7;
    }
    let mut out: Vec<u8> = Vec::with_capacity(len);
    while pos < data.len() {
        let tag = data[pos];
        pos += 1;
        match tag & 0x03 {
            0 => {
                let mut l = (tag >> 2) as usize;
                if l >= 60 {
                    let nbytes = l - 59;
                    if pos + nbytes > data.len() {
                        return Err("snappy: short literal len".into());
                    }
                    let mut v = 0usize;
                    for i in 0..nbytes {
                        v |= (data[pos + i] as usize) << (8 * i);
                    }
                    pos += nbytes;
                    l = v;
                }
                let l = l + 1;
                if pos + l > data.len() {
                    return Err("snappy: short literal".into());
                }
                out.extend_from_slice(&data[pos..pos + l]);
                pos += l;
            }
            kind => {
                let (length, offset) = match kind {
                    1 => {
                        if pos >= data.len() {
                            return Err("snappy: short copy".into());
                        }
                        let l = 4 + ((tag >> 2) & 0x7) as usize;
                        let off = (((tag >> 5) as usize) << 8) | data[pos] as usize;
                        pos += 1;
                        (l, off)
                    }
                    2 => {
                        if pos + 2 > data.len() {
                            return Err("snappy: short copy".into());
                        }
                        let l = 1 + (tag >> 2) as usize;
                        let off = u16::from_le_bytes([data[pos], data[pos + 1]]) as usize;
                        pos += 2;
                        (l, off)
                    }
                    _ => {
                        if pos + 4 > data.len() {
                            return Err("snappy: short copy".into());
                        }
                        let l = 1 + (tag >> 2) as usize;
                        let off =
                            u32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]])
                                as usize;
                        pos += 4;
                        (l, off)
                    }
                };
                if offset == 0 || offset > out.len() {
                    return Err("snappy: bad offset".into());
                }
                let start = out.len() - offset;
                for k in 0..length {
                    let b = out[start + k];
                    out.push(b);
                }
            }
        }
    }
    if out.len() != len {
        return Err("snappy: length mismatch".into());
    }
    Ok(out)
}

// --- LZ4 frame -------------------------------------------------------

fn xxhash32(data: &[u8], seed: u32) -> u32 {
    const P1: u32 = 0x9E3779B1;
    const P2: u32 = 0x85EBCA77;
    const P3: u32 = 0xC2B2AE3D;
    const P4: u32 = 0x27D4EB2F;
    const P5: u32 = 0x165667B1;
    let len = data.len() as u32;
    let mut pos = 0;
    let mut h: u32;
    if data.len() >= 16 {
        let mut v1 = seed.wrapping_add(P1).wrapping_add(P2);
        let mut v2 = seed.wrapping_add(P2);
        let mut v3 = seed;
        let mut v4 = seed.wrapping_sub(P1);
        while pos + 16 <= data.len() {
            let rd = |p: usize| u32::from_le_bytes(data[p..p + 4].try_into().unwrap());
            v1 = v1.wrapping_add(rd(pos).wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            v2 = v2.wrapping_add(rd(pos + 4).wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            v3 = v3.wrapping_add(rd(pos + 8).wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            v4 = v4.wrapping_add(rd(pos + 12).wrapping_mul(P2)).rotate_left(13).wrapping_mul(P1);
            pos += 16;
        }
        h = v1.rotate_left(1).wrapping_add(v2.rotate_left(7)).wrapping_add(v3.rotate_left(12)).wrapping_add(v4.rotate_left(18));
    } else {
        h = seed.wrapping_add(P5);
    }
    h = h.wrapping_add(len);
    while pos + 4 <= data.len() {
        let v = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
        h = h.wrapping_add(v.wrapping_mul(P3)).rotate_left(17).wrapping_mul(P4);
        pos += 4;
    }
    while pos < data.len() {
        h = h.wrapping_add((data[pos] as u32).wrapping_mul(P5)).rotate_left(11).wrapping_mul(P1);
        pos += 1;
    }
    h ^= h >> 15;
    h = h.wrapping_mul(P2);
    h ^= h >> 13;
    h = h.wrapping_mul(P3);
    h ^= h >> 16;
    h
}

fn lz4_block_decompress(data: &[u8], max_out: usize) -> Result<Vec<u8>, String> {
    let mut out: Vec<u8> = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        let token = data[pos];
        pos += 1;
        let mut lit_len = (token >> 4) as usize;
        if lit_len == 15 {
            loop {
                if pos >= data.len() {
                    return Err("lz4: short literal len".into());
                }
                let b = data[pos];
                pos += 1;
                lit_len += b as usize;
                if b != 255 {
                    break;
                }
            }
        }
        if pos + lit_len > data.len() {
            return Err("lz4: short literals".into());
        }
        out.extend_from_slice(&data[pos..pos + lit_len]);
        pos += lit_len;
        if pos >= data.len() {
            break;
        }
        if pos + 2 > data.len() {
            return Err("lz4: short offset".into());
        }
        let offset = u16::from_le_bytes([data[pos], data[pos + 1]]) as usize;
        pos += 2;
        let mut match_len = (token & 0x0f) as usize;
        if match_len == 15 {
            loop {
                if pos >= data.len() {
                    return Err("lz4: short match len".into());
                }
                let b = data[pos];
                pos += 1;
                match_len += b as usize;
                if b != 255 {
                    break;
                }
            }
        }
        let match_len = match_len + 4;
        if offset == 0 || offset > out.len() {
            return Err("lz4: bad offset".into());
        }
        let start = out.len() - offset;
        for k in 0..match_len {
            let b = out[start + k];
            out.push(b);
        }
        if out.len() > max_out {
            return Err("lz4: output too large".into());
        }
    }
    Ok(out)
}

pub fn lz4_frame_compress(data: &[u8]) -> Vec<u8> {
    // LZ4 frame, block-independent, uncompressed blocks (valid frame).
    let mut out = Vec::new();
    out.extend_from_slice(&0x184D2204u32.to_le_bytes());
    // FLG: version=01, block independence=1, no checksums, no content size.
    let flg: u8 = 0b0110_0000;
    let bd: u8 = 0x70; // max block 64KB... use 4MB code 7<<4
    let _ = bd;
    out.push(flg);
    out.push(0x70);
    let hc = (xxhash32(&[flg, 0x70], 0) >> 8) as u8;
    out.push(hc);
    for chunk in data.chunks(65536) {
        let size = chunk.len() as u32;
        out.extend_from_slice(&(size | 0x8000_0000).to_le_bytes());
        out.extend_from_slice(chunk);
    }
    if data.is_empty() {
        out.extend_from_slice(&0x8000_0000u32.to_le_bytes());
    }
    out.extend_from_slice(&0u32.to_le_bytes()); // EndMark
    out
}

pub fn lz4_frame_decompress(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.len() < 7 || u32::from_le_bytes(data[0..4].try_into().unwrap()) != 0x184D2204 {
        // Kafka's legacy LZ4 variant lacks the standard magic in old
        // deployments; modern brokers use the standard frame.
        return Err("lz4: bad frame magic".into());
    }
    let flg = data[4];
    if flg >> 6 != 1 {
        return Err("lz4: unsupported frame version".into());
    }
    let has_content_size = flg & 0x08 != 0;
    let has_content_checksum = flg & 0x04 != 0;
    let has_block_checksum = flg & 0x10 != 0;
    let mut pos = 6; // magic(4) + FLG + BD
    if has_content_size {
        pos += 8;
    }
    pos += 1; // header checksum
    if pos > data.len() {
        return Err("lz4: short header".into());
    }
    let mut out = Vec::new();
    loop {
        if pos + 4 > data.len() {
            return Err("lz4: short block header".into());
        }
        let size_field = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
        pos += 4;
        if size_field == 0 {
            break;
        }
        let uncompressed = size_field & 0x8000_0000 != 0;
        let size = (size_field & 0x7fff_ffff) as usize;
        if pos + size > data.len() {
            return Err("lz4: short block".into());
        }
        let block = &data[pos..pos + size];
        pos += size;
        if has_block_checksum {
            pos += 4;
        }
        if uncompressed {
            out.extend_from_slice(block);
        } else {
            let decoded = lz4_block_decompress(block, 4 * 1024 * 1024)?;
            out.extend_from_slice(&decoded);
        }
        if out.len() > 64 * 1024 * 1024 {
            return Err("lz4: output too large".into());
        }
    }
    if has_content_checksum {
        // trailing 4 bytes ignored (xxhash of content)
        let _ = pos;
    }
    Ok(out)
}

// --- Zstd (RFC 8878 frame format, raw/RLE blocks) ---------------

/// Compress as one standard zstd frame with raw blocks
/// (no compression): a valid frame any zstd decoder accepts.
pub fn zstd_compress(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 18 + data.len() / 131072 * 3);
    out.extend_from_slice(&[0x28, 0xB5, 0x2F, 0xFD]); // magic
    out.push(0xE0); // FCS flag 3 (8-byte), single-segment, no checksum/dict
    out.extend_from_slice(&(data.len() as u64).to_le_bytes());
    if data.is_empty() {
        out.extend_from_slice(&[0x01, 0x00, 0x00]); // last, raw, size 0
    }
    let mut chunks = data.chunks(131072).peekable();
    while let Some(chunk) = chunks.next() {
        let last = if chunks.peek().is_none() { 1u32 } else { 0u32 };
        let header = last | ((chunk.len() as u32) << 3);
        out.extend_from_slice(&header.to_le_bytes()[..3]);
        out.extend_from_slice(chunk);
    }
    out
}

/// Forward bit reader (little-endian bit order) used for FSE
/// table descriptions.
struct ZstdFwd<'a> {
    data: &'a [u8],
    pos: usize, // bit position
}

impl<'a> ZstdFwd<'a> {
    fn new(data: &'a [u8]) -> ZstdFwd<'a> {
        ZstdFwd { data, pos: 0 }
    }
    fn read(&mut self, n: usize) -> u32 {
        let mut v = 0u32;
        for i in 0..n {
            let byte = self.pos >> 3;
            let bit = if byte < self.data.len() {
                (self.data[byte] >> (self.pos & 7)) & 1
            } else {
                0
            };
            v |= (bit as u32) << i;
            self.pos += 1;
        }
        v
    }
    fn peek(&self, n: usize) -> u32 {
        let mut clone = ZstdFwd { data: self.data, pos: self.pos };
        clone.read(n)
    }
    fn byte(&mut self) -> Result<u8, String> {
        if self.pos % 8 != 0 || self.pos / 8 >= self.data.len() {
            return Err("kafka: zstd: truncated table description".into());
        }
        let b = self.data[self.pos / 8];
        self.pos += 8;
        Ok(b)
    }
    fn align(&mut self) {
        self.pos = (self.pos + 7) & !7;
    }
}

/// Backward bit reader for FSE/Huffman streams: the last byte
/// holds a sentinel 1-bit; bits are consumed downward from just
/// below it, first-consumed bit most significant.
struct ZstdBack<'a> {
    data: &'a [u8],
    next: i64, // bit index of the sentinel; reads go below it
}

impl<'a> ZstdBack<'a> {
    fn new(data: &'a [u8]) -> Result<ZstdBack<'a>, String> {
        let last = data.last().copied().unwrap_or(0);
        if last == 0 {
            return Err("kafka: zstd: bitstream missing sentinel bit".into());
        }
        let msb = 7 - last.leading_zeros() as i64;
        Ok(ZstdBack { data, next: (data.len() as i64 - 1) * 8 + msb })
    }
    fn read(&mut self, n: usize) -> u32 {
        // Bits at negative positions read as zero (past the start
        // of the stream, the FSE/Huffman end-of-stream condition).
        let mut v = 0u32;
        for _ in 0..n {
            self.next -= 1;
            let bit = if self.next >= 0 {
                (self.data[(self.next >> 3) as usize] >> (self.next & 7)) & 1
            } else {
                0
            };
            v = (v << 1) | bit as u32;
        }
        v
    }
}

fn highbit32(v: u32) -> u32 {
    31 - v.leading_zeros()
}

/// Read an FSE normalized-count table description. Returns the
/// per-symbol counts (-1 = less-than-1, 0 = absent, >0 =
/// frequency), the table log, and bytes consumed.
fn read_ncount(
    data: &[u8],
    max_sym: usize,
    max_log: u32,
) -> Result<(Vec<i16>, u32, usize), String> {
    let bad = |msg: &str| format!("kafka: zstd: {msg}");
    let mut f = ZstdFwd::new(data);
    let table_log = f.read(4) + 5;
    if table_log > max_log {
        return Err(bad("FSE table log too large"));
    }
    let mut nb_bits = table_log + 1;
    let mut remaining: i64 = (1i64 << table_log) + 1;
    let mut threshold: i64 = 1i64 << table_log;
    let mut counts = vec![0i16; max_sym + 2];
    let mut sym = 0usize;
    let mut prev0 = false;
    loop {
        if prev0 {
            // Zero-probability repeat flags (2 bits each, 3 =
            // read another).
            loop {
                let rep = f.read(2) as usize;
                sym += rep;
                if sym > max_sym + 1 {
                    return Err(bad("FSE count symbol overrun"));
                }
                if rep < 3 {
                    break;
                }
            }
            prev0 = false;
        }
        let max = (2 * threshold - 1) - remaining;
        let stream = f.peek((nb_bits + 1) as usize) as i64;
        let mut count: i64;
        if (stream & (threshold - 1)) < max {
            count = stream & (threshold - 1);
            f.read((nb_bits - 1) as usize);
        } else {
            count = stream & (2 * threshold - 1);
            if count >= threshold {
                count -= max;
            }
            f.read(nb_bits as usize);
        }
        count -= 1;
        if sym > max_sym + 1 {
            return Err(bad("FSE count symbol overrun"));
        }
        counts[sym] = count as i16;
        sym += 1;
        if count >= 0 {
            remaining -= count;
        } else {
            remaining -= 1;
        }
        prev0 = count == 0;
        if remaining < threshold {
            if remaining <= 1 {
                break;
            }
            nb_bits = highbit32(remaining as u32) + 1;
            threshold = 1i64 << (nb_bits - 1);
        }
    }
    f.align();
    Ok((counts, table_log, f.pos / 8))
}

/// An FSE decoding table: per state, the symbol, how many bits
/// to read for the next state, and the next-state baseline.
#[derive(Clone)]
struct FseTable {
    symbol: Vec<u16>,
    nbits: Vec<u8>,
    base: Vec<i32>,
    table_log: u32,
}

impl FseTable {
    fn build(counts: &[i16], table_log: u32) -> Result<FseTable, String> {
        let bad = |msg: &str| format!("kafka: zstd: {msg}");
        let size = 1usize << table_log;
        let mut symbol = vec![0u16; size];
        let mut sym_next = vec![0u32; counts.len()];
        let mut top = size; // low-probability symbols sit at [top, size)
        for (s, &c) in counts.iter().enumerate() {
            if c == -1 {
                top -= 1;
                symbol[top] = s as u16;
                sym_next[s] = 1;
            } else if c > 0 {
                sym_next[s] = c as u32;
            }
        }
        // Spread remaining symbols with the FSE step, skipping
        // the low-probability area after each placement (the
        // reference build advances past it, not by +1).
        let step = (size >> 1) + (size >> 3) + 3;
        let mut pos = 0usize;
        for (s, &c) in counts.iter().enumerate() {
            if c <= 0 {
                continue;
            }
            for _ in 0..c {
                symbol[pos] = s as u16;
                pos = (pos + step) % size;
                while pos > top - 1 {
                    pos = (pos + step) % size;
                }
            }
        }
        let mut nbits = vec![0u8; size];
        let mut base = vec![0i32; size];
        let mut next = sym_next;
        for state in 0..size {
            let s = symbol[state] as usize;
            let n = next[s];
            next[s] += 1;
            if n == 0 {
                return Err(bad("FSE table has unused symbol slot"));
            }
            let nb = table_log - highbit32(n);
            nbits[state] = nb as u8;
            base[state] = ((n << nb) as i32) - (size as i32);
        }
        Ok(FseTable { symbol, nbits, base, table_log })
    }
    fn init_state(&self, back: &mut ZstdBack) -> usize {
        back.read(self.table_log as usize) as usize
    }
    fn sym_of(&self, state: usize) -> u16 {
        self.symbol[state]
    }
    fn step_state(&self, state: usize, back: &mut ZstdBack) -> usize {
        (self.base[state] + back.read(self.nbits[state] as usize) as i32) as usize
    }
}

/// Huffman decoding table for one literals section. Codes are
/// assigned by (weight, symbol) ascending -- longest codes
/// first -- with the counter shifting right as lengths drop
/// (the zstd assignment, not the JPEG one).
struct ZstdHuff {
    max_bits: u32,
    nbits: Vec<u8>, // per symbol, 0 = absent
    map: std::collections::HashMap<(u8, u32), u16>,
}

impl ZstdHuff {
    fn from_weights(weights: &[u8]) -> Result<ZstdHuff, String> {
        let bad = |msg: &str| format!("kafka: zstd: {msg}");
        let total: u32 = weights
            .iter()
            .filter(|&&w| w > 0)
            .map(|&w| 1u32 << (w - 1))
            .sum();
        if total == 0 || (total & (total - 1)) != 0 {
            return Err(bad("huffman weights do not complete a tree"));
        }
        let max_bits = highbit32(total);
        if max_bits > 11 {
            return Err(bad("huffman code length over 11"));
        }
        if weights.iter().filter(|&&w| w > 0).count() < 2 {
            return Err(bad("huffman tree has fewer than two symbols"));
        }
        if !weights.contains(&1) {
            return Err(bad("huffman tree has no weight-1 symbol"));
        }
        let nbits: Vec<u8> = weights
            .iter()
            .map(|&w| if w > 0 { (max_bits + 1 - w as u32) as u8 } else { 0 })
            .collect();
        let mut order: Vec<usize> = (0..weights.len()).filter(|&i| weights[i] > 0).collect();
        order.sort_by_key(|&i| (weights[i], i));
        let mut map = std::collections::HashMap::new();
        let mut code: u32 = 0;
        let mut prev_len: Option<u8> = None;
        for sym in order {
            let b = nbits[sym];
            if let Some(p) = prev_len {
                if b < p {
                    code >>= p - b;
                }
            }
            map.insert((b, code), sym as u16);
            code += 1;
            prev_len = Some(b);
        }
        Ok(ZstdHuff { max_bits, nbits, map })
    }

    fn decode_stream(&self, data: &[u8], expected: usize) -> Result<Vec<u8>, String> {
        let bad = |msg: &str| format!("kafka: zstd: {msg}");
        if expected == 0 {
            return Ok(Vec::new());
        }
        let mut back = ZstdBack::new(data)?;
        let mut out = Vec::with_capacity(expected);
        for _ in 0..expected {
            let mut code: u32 = 0;
            let mut found = None;
            for len in 1..=self.max_bits {
                code = (code << 1) | back.read(1);
                if let Some(&sym) = self.map.get(&(len as u8, code)) {
                    found = Some(sym);
                    break;
                }
            }
            match found {
                Some(sym) => out.push(sym as u8),
                None => return Err(bad("bad huffman code in literals")),
            }
        }
        Ok(out)
    }
}

/// Read a Huffman tree description (FSE-compressed or direct
/// weights), deducing the final weight by tree completion.
/// Returns the table and bytes consumed.
fn read_huff_tree(data: &[u8]) -> Result<(ZstdHuff, usize), String> {
    let bad = |msg: &str| format!("kafka: zstd: {msg}");
    if data.is_empty() {
        return Err(bad("missing huffman tree description"));
    }
    let header = data[0];
    let mut weights: Vec<u8>;
    let consumed: usize;
    if header < 128 {
        let comp_size = header as usize;
        if data.len() < 1 + comp_size {
            return Err(bad("truncated huffman weights"));
        }
        let wstream = &data[1..1 + comp_size];
        let (counts, table_log, used) = read_ncount(wstream, 255, 6)?;
        let table = FseTable::build(&counts, table_log)?;
        if used >= wstream.len() {
            return Err(bad("huffman weights stream too short"));
        }
        let stream = &wstream[used..];
        let mut back = ZstdBack::new(stream)?;
        let mut st1 = table.init_state(&mut back);
        let mut st2 = table.init_state(&mut back);
        weights = Vec::new();
        loop {
            weights.push(table.sym_of(st1) as u8);
            if weights.len() > 255 {
                return Err(bad("too many huffman weights"));
            }
            if back.next < table.nbits[st1] as i64 {
                weights.push(table.sym_of(st2) as u8);
                break;
            }
            st1 = table.step_state(st1, &mut back);
            weights.push(table.sym_of(st2) as u8);
            if weights.len() > 255 {
                return Err(bad("too many huffman weights"));
            }
            if back.next < table.nbits[st2] as i64 {
                weights.push(table.sym_of(st1) as u8);
                break;
            }
            st2 = table.step_state(st2, &mut back);
        }
        consumed = 1 + comp_size;
    } else {
        let n = (header - 127) as usize;
        weights = Vec::with_capacity(n);
        for i in 0..n {
            let byte = data.get(1 + i / 2).copied().unwrap_or(0);
            weights.push(if i % 2 == 0 { byte >> 4 } else { byte & 15 });
        }
        consumed = 1 + (n + 1) / 2;
    }
    // Deduce the last weight: the weights (as 2^(w-1) shares)
    // must complete to the next power of two.
    let total: u32 = weights
        .iter()
        .filter(|&&w| w > 0)
        .map(|&w| 1u32 << (w - 1))
        .sum();
    if total == 0 {
        return Err(bad("huffman weights are all zero"));
    }
    let next_pow2 = 1u32 << (highbit32(total) + 1);
    let rest = next_pow2 - total;
    if rest == 0 || (rest & (rest - 1)) != 0 {
        return Err(bad("huffman weights cannot complete a tree"));
    }
    weights.push((highbit32(rest) + 1) as u8);
    Ok((ZstdHuff::from_weights(&weights)?, consumed))
}

/// Per-frame decoder state carried across compressed blocks:
/// the literals Huffman table (treeless blocks), the sequence
/// FSE tables (repeat mode), and the repeat-offset history.
struct ZstdState {
    huff: Option<std::rc::Rc<ZstdHuff>>,
    seq: Option<std::rc::Rc<SeqTables>>,
    reps: [u32; 3],
}

impl Default for ZstdState {
    fn default() -> ZstdState {
        // Repeat offsets start at 1, 4, 8 for a fresh frame.
        ZstdState { huff: None, seq: None, reps: [1, 4, 8] }
    }
}

#[derive(Clone)]
enum SeqTab {
    Fse(FseTable),
    Rle(u16),
}

#[derive(Clone)]
struct SeqTables {
    ll: SeqTab,
    of: SeqTab,
    ml: SeqTab,
}

impl SeqTab {
    fn sym(&self, state: Option<usize>) -> u16 {
        match self {
            SeqTab::Rle(sym) => *sym,
            SeqTab::Fse(tab) => tab.sym_of(state.unwrap_or(0)),
        }
    }
    fn init(&self, back: &mut ZstdBack) -> Option<usize> {
        match self {
            SeqTab::Rle(_) => None,
            SeqTab::Fse(tab) => Some(tab.init_state(back)),
        }
    }
    fn step(&self, state: Option<usize>, back: &mut ZstdBack) -> Option<usize> {
        match self {
            SeqTab::Rle(_) => None,
            SeqTab::Fse(tab) => Some(tab.step_state(state.unwrap_or(0), back)),
        }
    }
}

const LL_DEFAULT: [i16; 36] = [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1,
];
const ML_DEFAULT: [i16; 53] = [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
];
const OF_DEFAULT: [i16; 29] = [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
];

const LL_BASE: [u32; 36] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64,
    128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
];
const LL_BITS: [u32; 36] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11,
    12, 13, 14, 15, 16,
];
const ML_BASE: [u32; 53] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
    29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
    4099, 8195, 16387, 32771, 65539,
];
const ML_BITS: [u32; 53] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
];

fn read_seq_tab(
    data: &[u8],
    off: &mut usize,
    mode: u8,
    max_sym: usize,
    max_log: u32,
    default: &[i16],
    default_log: u32,
    prev: Option<&SeqTab>,
) -> Result<SeqTab, String> {
    let bad = |msg: &str| format!("kafka: zstd: {msg}");
    match mode {
        0 => Ok(SeqTab::Fse(FseTable::build(default, default_log)?)),
        1 => {
            let sym = data.get(*off).copied().ok_or_else(|| bad("truncated RLE sequence table"))?;
            *off += 1;
            Ok(SeqTab::Rle(sym as u16))
        }
        2 => {
            let (counts, table_log, used) = read_ncount(&data[*off..], max_sym, max_log)?;
            *off += used;
            Ok(SeqTab::Fse(FseTable::build(&counts, table_log)?))
        }
        _ => match prev {
            Some(tab) => Ok(tab.clone()),
            None => Err(bad("sequence table repeat without a previous block")),
        },
    }
}

/// Decode the literals section of a compressed block. Returns
/// the literals, the section length in the block, and (if a new
/// table was described) the Huffman table to keep for treeless
/// blocks.
fn parse_literals(
    block: &[u8],
    state: &ZstdState,
) -> Result<(Vec<u8>, usize, Option<std::rc::Rc<ZstdHuff>>), String> {
    let bad = |msg: &str| format!("kafka: zstd: {msg}");
    if block.is_empty() {
        return Err(bad("empty compressed block"));
    }
    let b0 = block[0] as usize;
    let lit_type = b0 & 3;
    let sf = (b0 >> 2) & 3;
    let need = |n: usize| -> Result<(), String> {
        if block.len() < n {
            Err(bad("truncated literals section header"))
        } else {
            Ok(())
        }
    };
    if lit_type <= 1 {
        let (regen, hdr) = if sf == 0 || sf == 2 {
            (b0 >> 3, 1)
        } else if sf == 1 {
            need(2)?;
            ((b0 >> 4) | ((block[1] as usize) << 4), 2)
        } else {
            need(3)?;
            ((b0 >> 4) | ((block[1] as usize) << 4) | ((block[2] as usize) << 12), 3)
        };
        if lit_type == 0 {
            if block.len() < hdr + regen {
                return Err(bad("raw literals overrun block"));
            }
            return Ok((block[hdr..hdr + regen].to_vec(), hdr + regen, None));
        }
        need(hdr + 1)?;
        return Ok((vec![block[hdr]; regen], hdr + 1, None));
    }
    // Compressed (2) or treeless (3) literals.
    let (regen, comp, hdr, streams) = match sf {
        0 => {
            need(3)?;
            let v = b0 | ((block[1] as usize) << 8) | ((block[2] as usize) << 16);
            ((v >> 4) & 0x3FF, (v >> 14) & 0x3FF, 3, 1)
        }
        1 => {
            need(3)?;
            let v = b0 | ((block[1] as usize) << 8) | ((block[2] as usize) << 16);
            ((v >> 4) & 0x3FF, (v >> 14) & 0x3FF, 3, 4)
        }
        2 => {
            need(4)?;
            let v = b0
                | ((block[1] as usize) << 8)
                | ((block[2] as usize) << 16)
                | ((block[3] as usize) << 24);
            ((v >> 4) & 0x3FFF, (v >> 18) & 0x3FFF, 4, 4)
        }
        _ => {
            need(5)?;
            let mut v = 0usize;
            for i in 0..5 {
                v |= (block[i] as usize) << (8 * i);
            }
            ((v >> 4) & 0x3FFFF, (v >> 22) & 0x3FFFF, 5, 4)
        }
    };
    if block.len() < hdr + comp {
        return Err(bad("compressed literals overrun block"));
    }
    let payload = &block[hdr..hdr + comp];
    let (huff, tree_len, new_table) = if lit_type == 2 {
        let (table, used) = read_huff_tree(payload)?;
        let rc = std::rc::Rc::new(table);
        (rc.clone(), used, Some(rc))
    } else {
        match &state.huff {
            Some(rc) => (rc.clone(), 0, None),
            None => return Err(bad("treeless literals without a previous huffman table")),
        }
    };
    let sdata = &payload[tree_len..];
    let lits = if streams == 1 {
        huff.decode_stream(sdata, regen)?
    } else {
        if sdata.len() < 6 {
            return Err(bad("truncated literals jump table"));
        }
        let s1 = u16::from_le_bytes([sdata[0], sdata[1]]) as usize;
        let s2 = u16::from_le_bytes([sdata[2], sdata[3]]) as usize;
        let s3 = u16::from_le_bytes([sdata[4], sdata[5]]) as usize;
        if 6 + s1 + s2 + s3 > sdata.len() {
            return Err(bad("literals jump table overruns streams"));
        }
        let s4 = sdata.len() - 6 - s1 - s2 - s3;
        let sizes = [s1, s2, s3, s4];
        let per = (regen + 3) / 4;
        let counts = [per, per, per, regen - 3 * per];
        let mut lits = Vec::with_capacity(regen);
        let mut p = 6usize;
        for i in 0..4 {
            lits.extend_from_slice(&huff.decode_stream(&sdata[p..p + sizes[i]], counts[i])?);
            p += sizes[i];
        }
        lits
    };
    if lits.len() != regen {
        return Err(bad("literals size mismatch"));
    }
    Ok((lits, hdr + comp, new_table))
}

/// Decode one compressed block, appending to the frame output
/// and carrying Huffman/sequence/repeat state across blocks.
fn decode_compressed_block(
    block: &[u8],
    out: &mut Vec<u8>,
    state: &mut ZstdState,
) -> Result<(), String> {
    let bad = |msg: &str| format!("kafka: zstd: {msg}");
    let (lits, lit_len, new_table) = parse_literals(block, state)?;
    if let Some(table) = new_table {
        state.huff = Some(table);
    }
    let seq_data = &block[lit_len..];
    if seq_data.is_empty() {
        out.extend_from_slice(&lits);
        return Ok(());
    }
    let b0 = seq_data[0] as usize;
    let (nseq, hdr) = if b0 < 128 {
        (b0, 1)
    } else if b0 < 255 {
        if seq_data.len() < 2 {
            return Err(bad("truncated sequence count"));
        }
        (((b0 - 0x80) << 8) + seq_data[1] as usize, 2)
    } else {
        if seq_data.len() < 3 {
            return Err(bad("truncated sequence count"));
        }
        (seq_data[1] as usize + ((seq_data[2] as usize) << 8) + 0x7F00, 3)
    };
    if nseq == 0 {
        out.extend_from_slice(&lits);
        return Ok(());
    }
    // Symbol compression modes, then the three table descriptions.
    let modes = seq_data.get(hdr).copied().ok_or_else(|| bad("truncated sequence header"))?;
    let prev_tabs = state.seq.clone();
    let prev_ref = prev_tabs.as_deref();
    let mut off = hdr + 1;
    let ll = read_seq_tab(
        seq_data,
        &mut off,
        (modes >> 6) & 3,
        35,
        9,
        &LL_DEFAULT,
        6,
        prev_ref.map(|t| &t.ll),
    )?;
    let of = read_seq_tab(
        seq_data,
        &mut off,
        (modes >> 4) & 3,
        31,
        8,
        &OF_DEFAULT,
        5,
        prev_ref.map(|t| &t.of),
    )?;
    let ml = read_seq_tab(
        seq_data,
        &mut off,
        (modes >> 2) & 3,
        52,
        9,
        &ML_DEFAULT,
        6,
        prev_ref.map(|t| &t.ml),
    )?;
    let tabs = SeqTables { ll, of, ml };
    let stream = &seq_data[off..];
    let mut back = ZstdBack::new(stream)?;
    let mut ll_st = tabs.ll.init(&mut back);
    let mut of_st = tabs.of.init(&mut back);
    let mut ml_st = tabs.ml.init(&mut back);
    let mut lit_pos = 0usize;
    let mut reps = state.reps;
    for i in 0..nseq {
        let ll_code = tabs.ll.sym(ll_st) as usize;
        let of_code = tabs.of.sym(of_st) as usize;
        let ml_code = tabs.ml.sym(ml_st) as usize;
        if ll_code >= LL_BASE.len() || ml_code >= ML_BASE.len() {
            return Err(bad("sequence code out of range"));
        }
        let of_val = (1u32 << of_code) + back.read(of_code);
        let ml_len = (ML_BASE[ml_code] + back.read(ML_BITS[ml_code] as usize)) as usize;
        let ll_len = (LL_BASE[ll_code] + back.read(LL_BITS[ll_code] as usize)) as usize;
        if i + 1 != nseq {
            ll_st = tabs.ll.step(ll_st, &mut back);
            ml_st = tabs.ml.step(ml_st, &mut back);
            of_st = tabs.of.step(of_st, &mut back);
        }
        if lit_pos + ll_len > lits.len() {
            return Err(bad("literals overrun in sequence"));
        }
        out.extend_from_slice(&lits[lit_pos..lit_pos + ll_len]);
        lit_pos += ll_len;
        let offset: usize = if of_val > 3 {
            let offset = (of_val - 3) as usize;
            reps = [offset as u32, reps[0], reps[1]];
            offset
        } else if ll_len == 0 {
            let offset = match of_val {
                1 => reps[1],
                2 => reps[2],
                _ => reps[0].saturating_sub(1),
            };
            if offset == 0 {
                return Err(bad("repeat offset underflow"));
            }
            reps = [offset, reps[0], reps[1]];
            offset as usize
        } else {
            let sel = reps[(of_val - 1) as usize];
            reps = match of_val {
                1 => reps,
                2 => [reps[1], reps[0], reps[2]],
                _ => [reps[2], reps[0], reps[1]],
            };
            sel as usize
        };
        if offset == 0 || offset > out.len() {
            return Err(bad("match offset out of range"));
        }
        let start = out.len() - offset;
        for k in 0..ml_len {
            let byte = out[start + k];
            out.push(byte);
        }
    }
    out.extend_from_slice(&lits[lit_pos..]);
    state.reps = reps;
    state.seq = Some(std::rc::Rc::new(tabs));
    Ok(())
}

/// Decode zstd frames: skippable and standard frames; raw, RLE,
/// and compressed (Huffman literals + FSE sequences) blocks.
pub fn zstd_decompress(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    let bad = |msg: &str| format!("kafka: zstd: {msg}");
    while pos < data.len() {
        if data.len() - pos < 4 {
            return Err(bad("truncated frame"));
        }
        let magic = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
        pos += 4;
        if (0x184D2A50..=0x184D2A5F).contains(&magic) {
            // Skippable frame.
            if data.len() - pos < 4 {
                return Err(bad("truncated skippable frame"));
            }
            let size = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
            pos += 4 + size;
            if pos > data.len() {
                return Err(bad("skippable frame overruns input"));
            }
            continue;
        }
        if magic != 0xFD2FB528 {
            return Err(bad("bad magic"));
        }
        if pos >= data.len() {
            return Err(bad("truncated frame header"));
        }
        let descriptor = data[pos];
        pos += 1;
        let fcs_flag = descriptor >> 6;
        let single_segment = descriptor & 0x20 != 0;
        let checksum = descriptor & 0x04 != 0;
        let dict_flag = descriptor & 0x03;
        if !single_segment {
            pos += 1; // window descriptor
        }
        pos += match dict_flag { 0 => 0, 1 => 1, 2 => 2, _ => 4 };
        let fcs_len = match (fcs_flag, single_segment) {
            (0, true) => 1,
            (0, false) => 0,
            (1, _) => 2,
            (2, _) => 4,
            _ => 8,
        };
        pos += fcs_len;
        if pos > data.len() {
            return Err(bad("truncated frame header"));
        }
        let mut state = ZstdState::default();
        // Content blocks.
        loop {
            if data.len() - pos < 3 {
                return Err(bad("truncated block header"));
            }
            let header = u32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], 0]);
            pos += 3;
            let last = header & 1 != 0;
            let block_type = (header >> 1) & 0x3;
            let block_size = (header >> 3) as usize;
            match block_type {
                0 => {
                    if data.len() - pos < block_size {
                        return Err(bad("raw block overruns input"));
                    }
                    out.extend_from_slice(&data[pos..pos + block_size]);
                    pos += block_size;
                }
                1 => {
                    if pos >= data.len() {
                        return Err(bad("truncated RLE block"));
                    }
                    let byte = data[pos];
                    pos += 1;
                    out.extend(std::iter::repeat_n(byte, block_size));
                }
                2 => {
                    if data.len() - pos < block_size {
                        return Err(bad("compressed block overruns input"));
                    }
                    decode_compressed_block(&data[pos..pos + block_size], &mut out, &mut state)?;
                    pos += block_size;
                }
                _ => return Err(bad("reserved block type")),
            }
            if last {
                break;
            }
        }
        if checksum {
            pos += 4;
            if pos > data.len() {
                return Err(bad("truncated checksum"));
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zstd_roundtrip() {
        for data in [
            Vec::new(),
            b"a".to_vec(),
            b"hello kafka".to_vec(),
            (0..200_000u32).map(|i| (i % 251) as u8).collect::<Vec<u8>>(),
        ] {
            let frame = zstd_compress(&data);
            assert_eq!(zstd_decompress(&frame).expect("decode own frame"), data);
        }
        // Through the codec dispatch (codec 4).
        let frame = compress(4, b"dispatch").expect("compress");
        assert_eq!(decompress(4, &frame).expect("decompress"), b"dispatch");
    }

    #[test]
    fn zstd_decodes_reference_rle_frame() {
        // Hand-built per RFC 8878: single-segment frame, 2-byte
        // FCS (1000 - 256), one RLE block of 1000 'a' bytes.
        let mut frame = vec![0x28, 0xB5, 0x2F, 0xFD, 0x60];
        frame.extend_from_slice(&744u16.to_le_bytes());
        frame.extend_from_slice(&[0x43, 0x1F, 0x00, b'a']);
        assert_eq!(zstd_decompress(&frame).expect("decode rle"), vec![b'a'; 1000]);
    }
    fn hex_bytes(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn zstd_decodes_reference_compressed_frames() {
        // Reference frames produced by the zstd CLI (raw/RLE/
        // Huffman/FSE literals and sequences, 1- and 4-stream
        // literals, single- and multi-block frames, windowed
        // and single-segment headers). Payloads are regenerated
        // from the formulas used to create the fixtures.
        let cases: Vec<(Vec<u8>, Vec<u8>)> = vec![
            // small: payload 540 bytes, sha256 c9024b19dbefca3d...
            (hex_bytes("28b52ffd641c01b50100d40254686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e2001006587aa2a036b2b19da"), b"The quick brown fox jumps over the lazy dog. ".repeat(12)),
            // text50k: payload 55200 bytes, sha256 9ef1e95b415990aa...
            (hex_bytes("28b52ffd64a0d61d1b0086f66616704fd628f5f4f70c0406fedf8bb429292951bdeafe998800520052004992244992244992244992244992244992348ebb9cc268348ebb9cc2381ac75d4e61bc71dce514861bc75d4e61b471dce514061bc75d4e61ac71dce514861ac75d4e61a471dce51480068704890409830703880003068788000489048a80820187058b818700038809898a8483800289888b008b0a07888780018583018500014640018403810144dbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66d922449922449922449922449922449922449922449922449922449922449922449922449929424499224499224499224499224499224499224496ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb62d499224499224499224499224499224499224499224499224499224499224499224499224496edbb66ddbb66ddbb66ddbb66d5bffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff6fdbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddb6ddbb66ddbb66d8321a812c0cfcefe1df2d7d90d1248105841e0ff7f04823f8f88888888888811111111111131222222424444444444c488888818212222222222222222222244448c888888888888111122222222224644444444848888888888888888111121464444444444444444448811111111111111111111222222c688888888888808111111111111312222224244444444448c88888818212222222222222222222244448c888888888818111122222222224644444444848888888888888888111151444444444444444444448811111111111111111111222262c488888888888808111111111111312222224244444444c48888888818212222222222222222222244448c888888888811111122222222224644444444848888888888888888111143444444444444444444448811111111111111111111222246c4888888888888081111111111113122222242444444448c8888888818212222222222222222222244448c8888888818111111222222222246444444448488888888888828c7bd263f464444842520222222621510224644c42a20222222621510212222621510111111b10a88081111b10a10111111b10a88881011b10a88888888f02157884c5b00af36c4798018"), (0..800).flat_map(|i| format!("record {i:06}: kafka proxy zstd fixture payload with some repetition\n").into_bytes()).collect()),
            // mid5k: payload 5760 bytes, sha256 68e9443e4d853c59...
            (hex_bytes("28b52ffd648015050600020b1d16903579c0343bba1c655447ffcf7185144989dff58313ffffffffffffffdfbc9a78f6eae6d5c4b31737af269ebdb67935f1eca5cdab8967af6c5e4d3c7b61f36ae2d9eb9a5713cf5ed6bc9a78f67af36ae2d901455112429072080c2390397406e550310c42814324545545c3618472d040180178a811b0bbff77f035b60312f81304fe3f41c0c51f0000000110880c4b08848165078080b30320c1d90110e2ec0008747600049c3b0002ce1e000167278080b3434060a93c98005905227afacf"), (0..120).flat_map(|i| format!("mid record {i:04} with some text to compress well\n").into_bytes()).collect()),
            // big200k: payload 200000 bytes, sha256 b88cde4741571cb0...
            (hex_bytes("28b52ffda4400d0300141300b40f00070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef501080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f9050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf481f6a8e1efff9f01e16bb51d124810f8ffff80c1e3ef1bfd0403fb4d35d554539f7abaa9a79b7e6ad34f6faae9a69e7efaa9a79baae9a69f7abaa9a79b7e6aa69f6eaae9a69e7efaa94e37f574d34f6dbaa9a733fdd4a69f6eaae9a69eeef4534f37f574d34f3d9da9a733fdd4a69f6eaae94c3dfdf4534f37f574d39d7abaa9a79b7e6ad39bce54d34d3dfdf4534f37d5e9a69f7abaa9a79b7e6aa69f6eaae94c3dfdf4539d6eeae9a69f7abaa9a733fdd4a69f6eaae9a69eeef4a69e6eeae9a69f7a3a534f37fdd4a69f6eaae94c3dfdf4534f37b5e9a63bf574534f37fdd4a69fce54d34d3dfdf4534f37d5e9a69fda74534f37fdd44c3fdd54d34d3dfdf4539d6eeae9a69f7abaa9a763faa94d3fdd54d34d3ddde9a79e6eeae9a69f7a3a534f37fdd4a637dd54d3997afae9a79e6eeae9a63bf574534f37fdd4a69fce54d3997afae9a79e6eaad34d3ff574534f37fdd44c3fdd54d34d35abd553ed7fc2f77ec05f055500000001003d0d03f6b90602c008facb"), (0..200_000u32).map(|i| ((i * 7 + (i >> 8)) % 251) as u8).collect()),
            // text200k: payload 204000 bytes, sha256 4b752688cffcb5d5...
            (hex_bytes("28b52ffda4e01c0300344200ea82f40e1a5035a8e40f253d94f45012a8aa4ad77b5744444aeceecc885903f300e800e0006ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb62d499224499224499224499224499224499224499224499224499224499224499224499224496edbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66d9b244992244992244992244992244992244992244992244992244992244992244992244992248dc45d4e6146e22ea720237197538891b8cb297c24ee720a1e89bb9c4247e22ea7c091b8cb296c24ee720a1a89bb9c001889bb9cc20102101470a0c10602343081011740704041040e58b0c04106101c70f00006104c30c00103042860810407062450c14100e1c08007146820333333333333333333333333333333333333333333333333333333333333333333333333333333333322222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222221111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff6fdbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddb6ddbb66ddbb66ddbb66ddbb66ddbb66d6ddb92244992244992244992244992244992244992244992244992244992244992244992244992e4b66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb64992244992244992244992244992244992244992244992244992244992244992244992244952505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050505050d0cccccccccccccccc4c333333333333333333333333333322222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222221111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff6fdbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddb6ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddb06878aa81300fc4bfb3307e3afd16e139040c00804fc8f40c07f0fff000000010002000004000800000000200000040000000010000002000000000000000000000000000000002000000000800000000000020000000000000000000400000000000000000000000000001000000000400000000000020000000000000000000100000000000000000000000000000800000000200000000080000000000000000000800000000000000000000000000000000400000000100000000040000000000000000000400000000000000000000000000000000200000000080000000020000000000000000000400000000000000000000000000000000100000000040000000020000000000000000000200000000000000000000000000000800000000000040000000010000000000000000000080000000000000000000000000000400000000000010000000004000000000000000000040000000000000000000000000000200000000080000000000002000000000000000000040000000000000000000000000000100000000040000000000002000000000000000000020000000000000000000000000000080000000040000000000001000000000000000000010000000000000000000000000c50fcda551de990f77fee2f5fed111eec5e67fae6d53ff681ef7b865fbbaa231df2fecffde5ab3dc283ddeb4cdfbcfac73ef07dcff06b5775a443deffb9bf7cb54778b07b9de99b57ffb00f7cdf33fcda551de990f77fee2f5fed111eec5e67fae6d53ff681ef7b865fbbaa231df2fecffde5ab3dc283ddeb4cdfbcfac73ef07dcff06b5775a443deffb9bf7cb5c70700000001200000000000000000010000000004000000000000000000040000000000000000000000000000200000000080000000000002000000000000000000040000000000000000000000000000100000000040000000000002000000000000000000020000000000000000000000000000040000000020000000008000000000000000000080000000000000000000000000000000040000000010000000004000000000000000000040000000000000000000000000000000020000000008000000002000000000000000000040000000000000000000000000000000010000000004000000001000000000000000000020000000000000000000000000000080000000000004000000001000000000000000000010000000000000000000000000000040000000000001000000000400000000000000000004000000000000000000000000000020000000008000000000000200000000000000000004000000000000000000000000000010000000004000000000000100000000000000000002000000000000000000000000000008000000002000000000000100000000000000000001000000000000000000000000000008000000002000000000800000000000000000008000000000000000000000000000004a6052df000000003c5c0700000010600e00000001403d0000000005700000080018f00000200010f80100000038b003040000a0e00710000080803f4000000018435887eea82e044017c0c6453525005b49240892006f00700092244992244992a4b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b099999999999999999999999999999999999999999999999999999999999999999999999908026ddbb66ddb9624499224499224499224499224499224499224499224499224499224499224499224499224b76ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb64d92244992244992244992244992244992244992244992244992244992240511111111f1ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb6ddb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb60d33333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333332222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111118431981380fa070013f0ffff23103018ff000000080100000204000000000000000000000000200000000000000002000004000000000000000800001020004000000000000000000000000100000400000000000000000000080000204000000000010000000080000000020000000000000000000008000010000000000000000002004000080001000000000000000000000400000800000000000000000000200000800010000000400000000000020000080000000000000000000010000040000000000000000080000001000204000000000000000000001000002000000000000000000000800000000200040000001000000000080000100000000000000000000040000000010000000000000000200004008010000000000000000000002000008000000000000000000000000200000800000100000004000000200000400000000000000000000000010000040000000000000000000810000060000000000000000000008000000002000000000000000000000800002000004000000000020000400000000100000000000000000000040000100000000000000000000042000080100000000000000000000002000008000000000000000000002000008000000020000000800000000100000400000000000000000000100000400000000000000000000080010000022ca85ffcf9c18767bcf8e387377ef9e3870f9e79e1cf0fdefce2cf0f3e3ce3c51f3fbcf1cb1f3f7cf0cc0b7f7ef0e6177f7ef0e1192ffef8e18d5ffef8e183675ef8f38337bff8f3830fcf78f1c70f6ffcf2c70f1f3cf3c29f1fbcf9c59f1f7c78c68b3f7e78e3973f7ef8e09917fefce0cd2ffefce0c3335efcf1c3db2100004000000000020000000000000100000000000010000040000000000000000000800001720004069781c9c4"), (0..3000).flat_map(|i| format!("line {i:06}: the quick brown fox jumps over the lazy dog 0123456789\n").into_bytes()).collect()),
            // text200k_w15: payload 204000 bytes, sha256 4b752688cffcb5d5...
            (hex_bytes("28b52ffd8428e01c0300cc110046e2411a603764380f253d94f450620641e41a21646f2993812510a974055e002c0028008b248b921c332d72162539665ac42c4a72ccb4c8162539665a448b921c332df2a224c74c8bb828c931d3022c4a72ccb4c881005170686c08344c185c401c14110e160b4706c4c1f1800131317030102858481c060915470072183c283404ffffaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8b921c332db22c4a72ccb488b228c9315392244992244992244992244992244992a4ffffffffffffffffffffffffffffffffffffffffffffffdbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66d9b24499224499224499224499224499224499224490a81e4a811d02bedcf1ce16bb41b1248101841e0ff7f05843f0000000000000100000000c00000000000000204000000800000200000000400000001000200000000041000000000004200000000001000020000000800001000002000000080001000000000008400000000002040000000008000000200004000000008000002000000408000000000000006000000000001200000000008000001000002000000080010000000004008000000000020040000000008001000000040000080000020000000000480000000000060000000000000010200000080000010000000c20a932a18000000600efa0100200024a01f0020048004f40300400048403f0000080009e8070080002001fd0000100012d00f0000024002fa0100200048403f00000400cf9d38d4a90a115001843fec1200479e5447004f005b00c718638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c61863b66ddbb66ddbb6294992244992244992244992244992244972ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce098aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa22449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449cbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22c8aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2284a81e39811e01f0012f81304fe7f0501ff000000000040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c065025401ac120087644165003e0025004a72ccb488162539665ae445498e991671519263a64510c445498e991659162539665a445994e4986991645192633436041a260c2e200e8a08078b852303e2e078c0809818381808142c240e83848a2360674110e430785068005894e49869910301a2e008aaaaaaaaaaaaaaaaaaaaaaaaaa8a88888888888888888888888888888888888888888888888888888888b828c931d32267519263a645cca224c74c8b6c09ffffffffffffffffffffffffffffffffffffffffffffffffffaaaaaaaaaaaaaaaaaaaaaa1adbb66ddbb66ddbb66ddbb66ddbb66ddbb6499224499224499224499224499224499224499224499224499224499224499224499224495281e3a821e40efb7f06e16bb41b124810f8ff04814f10d8c51f000002000010000000080000000000001000000000000020000000000000800000000000000001000000000000040000000000001000000000000010000000000000400000000000008000000000000000020000000000000800000000000008000000000000200000000000004000000000000000010000000000000400000000000004000000000000100000000000002000000000000080000000000000000200000000000004000000000000080000000000001000000000000040001000fff349e7f9e772cef3cf73cef3cf73cef3cf73cef3cf73cef3cf738ee79fe79ce79fe79ce7d2a74f6a1e000000800f7a0000000020d401000c00c0000e00000200423b000001000cee00000200407807001800c0842f0000010020fc0102048060f00e00300080c11f00803e870e75aaae00fc55841200479e513f004c005a00c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c3166dbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb6848ae79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c738e31c618638c31c618638c31c618638c31c618638c31268aa2288aa22449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449929c73ce39e79c73ce3901cbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22c8aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2284a81e39811e01f0012f8ff150412047eff000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c04dd32a3414000727476a004f002800888b921c332d82202f4a72ccb4c8b228c931d322caa224c74c8b248b921c332d72162539665ac42c4a72ccb4c8162539665a448b83c5c2910171703c60404c0c1c0c040a161201ca8b0872183c2834002c4a72ccb4c881005170686c08341c060915c784c105c4411111c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c88b921c332df2a224c74c1bffffffffffffffffffffffffffafaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8a1cdbb66d9b24499224499224499224499224499224499224499224499224499224499224499224499224fdffffffffffffffffffff7f81e3a821cc1cf66b37e16bb41b124810f84710f85f4140cb1f01000000000000000080002000000140001000800020000800200010000400200008000200100004000100040001800000040001400000018000200080002000080080002000080020001000040010000400010010000400010004000180000002800020000001800020008000200008004000100004002000100004001000040001000800028000000400018000000280002000800040001000800020000800400010000400100008000200100004000100080002089ecb276f4eaedc793973c8cd9d9b276f4eaedc793973e4e6cecd936b4eaedc793973e4e6cecd93372757eebc1c73e4e6cecd93372757eebc9c397273e7e692372757eebc9c397273e7e662a24f6a0f200000000f780800000040f803801000001ab400014000f0d08300000000841f0000000420f40102800020a18700000000083f0000000440e80304000140426f32850fd5a41201fe2a141200471e4e36004c005500c618638c31c618638c31c618638c31c61863b66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb66ddbb68323e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e718638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c31c618638c312649922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449922449929c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c73ce39e79c138aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2288aa2284992244992244992244992244992244992244992244981e39811e01f0012f80481ff7f0501ff000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c04d4fabdd0400d3c614cbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22ccbb22c8aa2288aa22804016d58010012f8ffff4f20f803000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e008089781c9c4"), (0..3000).flat_map(|i| format!("line {i:06}: the quick brown fox jumps over the lazy dog 0123456789\n").into_bytes()).collect()),
        ];
        for (frame, expected) in cases {
            assert_eq!(zstd_decompress(&frame).expect("decode ref frame"), expected);
        }
    }
}
