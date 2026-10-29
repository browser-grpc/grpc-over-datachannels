//! Record-batch compression codecs used by the Kafka
//! protocol: gzip (RFC1952 + DEFLATE), snappy (raw block
//! format), LZ4 (frame format). Dependency-free; compressors
//! favour correctness over ratio. Zstd uses the standard
//! frame format with raw blocks; its decoder handles raw and
//! RLE blocks (FSE/Huffman-compressed blocks report an error).

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

/// Decode zstd frames: skippable and standard frames, raw and
/// RLE blocks. FSE/Huffman-compressed blocks are rejected.
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
                2 => return Err(bad("compressed blocks not supported")),
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
}
