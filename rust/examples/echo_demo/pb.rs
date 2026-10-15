//! Hand-written protobuf messages for `proto/echo.proto`.
//!
//! Deliberately minimal (two messages, three field types) so the example
//! needs no protobuf codegen dependency — real projects point the plugin's
//! `message_module` at prost/protobuf-codegen output instead (with the
//! `prost` feature those types satisfy `grpc_dc::Message` automatically).
//! The wire bytes are genuine protobuf: `EchoRequest{message:"hi",
//! count:2}` encodes to the golden fixture `0a0268691002`.

use grpc_dc::{Message, Status};

fn put_varint(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn put_tag(field: u32, wire: u32, out: &mut Vec<u8>) {
    put_varint(((field << 3) | wire) as u64, out);
}

fn put_string(field: u32, value: &str, out: &mut Vec<u8>) {
    if value.is_empty() {
        return;
    }
    put_tag(field, 2, out);
    put_varint(value.len() as u64, out);
    out.extend_from_slice(value.as_bytes());
}

fn put_int32(field: u32, value: i32, out: &mut Vec<u8>) {
    if value == 0 {
        return;
    }
    put_tag(field, 0, out);
    put_varint(value as u64, out);
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn varint(&mut self) -> Result<u64, Status> {
        let mut result: u64 = 0;
        let mut shift = 0;
        loop {
            let byte = *self
                .bytes
                .get(self.pos)
                .ok_or_else(|| Status::invalid_argument("truncated varint"))?;
            self.pos += 1;
            result |= ((byte & 0x7f) as u64) << shift;
            if byte & 0x80 == 0 {
                return Ok(result);
            }
            shift += 7;
            if shift >= 64 {
                return Err(Status::invalid_argument("varint too long"));
            }
        }
    }

    /// Returns (field, wire, value-bytes-or-varint-bytes).
    fn field(&mut self) -> Result<Option<(u32, u32, Vec<u8>)>, Status> {
        if self.pos >= self.bytes.len() {
            return Ok(None);
        }
        let tag = self.varint()?;
        let (field, wire) = ((tag >> 3) as u32, (tag & 7) as u32);
        let value = match wire {
            0 => {
                let start = self.pos;
                self.varint()?;
                // Re-read as raw value:
                let mut r2 = Reader { bytes: self.bytes, pos: start };
                let v = r2.varint()?;
                v.to_le_bytes().to_vec()
            }
            2 => {
                let len = self.varint()? as usize;
                let end = self.pos + len;
                let slice = self
                    .bytes
                    .get(self.pos..end)
                    .ok_or_else(|| Status::invalid_argument("truncated bytes field"))?;
                self.pos = end;
                slice.to_vec()
            }
            1 => {
                let end = self.pos + 8;
                let slice = self.bytes.get(self.pos..end).ok_or_else(|| {
                    Status::invalid_argument("truncated fixed64")
                })?;
                self.pos = end;
                slice.to_vec()
            }
            5 => {
                let end = self.pos + 4;
                let slice = self.bytes.get(self.pos..end).ok_or_else(|| {
                    Status::invalid_argument("truncated fixed32")
                })?;
                self.pos = end;
                slice.to_vec()
            }
            _ => return Err(Status::invalid_argument(format!("bad wire type {wire}"))),
        };
        Ok(Some((field, wire, value)))
    }
}

fn varint_value(raw: &[u8]) -> i32 {
    let mut buf = [0u8; 8];
    buf[..raw.len().min(8)].copy_from_slice(&raw[..raw.len().min(8)]);
    u64::from_le_bytes(buf) as i32
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EchoRequest {
    pub message: String,
    pub count: i32,
    pub delay_ms: i32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EchoResponse {
    pub message: String,
    pub index: i32,
}

impl Message for EchoRequest {
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        put_string(1, &self.message, &mut out);
        put_int32(2, self.count, &mut out);
        put_int32(3, self.delay_ms, &mut out);
        out
    }

    fn decode(bytes: &[u8]) -> Result<Self, Status> {
        let mut msg = Self::default();
        let mut reader = Reader { bytes, pos: 0 };
        while let Some((field, _wire, value)) = reader.field()? {
            match field {
                1 => msg.message = String::from_utf8_lossy(&value).into_owned(),
                2 => msg.count = varint_value(&value),
                3 => msg.delay_ms = varint_value(&value),
                _ => {}
            }
        }
        Ok(msg)
    }
}

impl Message for EchoResponse {
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        put_string(1, &self.message, &mut out);
        put_int32(2, self.index, &mut out);
        out
    }

    fn decode(bytes: &[u8]) -> Result<Self, Status> {
        let mut msg = Self::default();
        let mut reader = Reader { bytes, pos: 0 };
        while let Some((field, _wire, value)) = reader.field()? {
            match field {
                1 => msg.message = String::from_utf8_lossy(&value).into_owned(),
                2 => msg.index = varint_value(&value),
                _ => {}
            }
        }
        Ok(msg)
    }
}
