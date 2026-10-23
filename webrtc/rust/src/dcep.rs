//! DCEP (RFC 8832): DATA_CHANNEL_OPEN/ACK over SCTP PPID 50, and the
//! channel-type byte mapping to SCTP partial-reliability policies.

use alloc::string::String;
use alloc::vec::Vec;
use crate::sctp::SendOptions;

pub const PPID_DCEP: u32 = 50;
pub const PPID_STRING: u32 = 51;
pub const PPID_BINARY: u32 = 53;
pub const PPID_STRING_EMPTY: u32 = 56;
pub const PPID_BINARY_EMPTY: u32 = 57;

pub const MSG_OPEN: u8 = 0x03;
pub const MSG_ACK: u8 = 0x02;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reliability {
    Reliable,
    MaxRetransmits(u32),
    MaxLifetimeMs(u64),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChannelParams {
    pub ordered: bool,
    pub reliability: Reliability,
    pub priority: u16,
    pub label: String,
    pub protocol: String,
}

impl Default for ChannelParams {
    fn default() -> Self {
        Self {
            ordered: true,
            reliability: Reliability::Reliable,
            priority: 0,
            label: String::new(),
            protocol: String::new(),
        }
    }
}

impl ChannelParams {
    pub fn channel_type(&self) -> u8 {
        let base = match self.reliability {
            Reliability::Reliable => 0x00,
            Reliability::MaxRetransmits(_) => 0x01,
            Reliability::MaxLifetimeMs(_) => 0x02,
        };
        if self.ordered {
            base
        } else {
            base | 0x80
        }
    }

    pub fn reliability_param(&self) -> u32 {
        match self.reliability {
            Reliability::Reliable => 0,
            Reliability::MaxRetransmits(n) => n,
            Reliability::MaxLifetimeMs(ms) => ms as u32,
        }
    }

    pub fn from_type(channel_type: u8, reliability_param: u32) -> (bool, Reliability) {
        let ordered = channel_type & 0x80 == 0;
        let reliability = match channel_type & 0x7f {
            0x01 => Reliability::MaxRetransmits(reliability_param),
            0x02 => Reliability::MaxLifetimeMs(reliability_param as u64),
            _ => Reliability::Reliable,
        };
        (ordered, reliability)
    }

    pub fn send_options(&self) -> SendOptions {
        SendOptions {
            unordered: !self.ordered,
            max_retransmits: match self.reliability {
                Reliability::MaxRetransmits(n) => Some(n),
                _ => None,
            },
            max_lifetime_ms: match self.reliability {
                Reliability::MaxLifetimeMs(ms) => Some(ms),
                _ => None,
            },
        }
    }
}

pub fn encode_open(params: &ChannelParams) -> Vec<u8> {
    let mut out = vec![MSG_OPEN, params.channel_type()];
    out.extend_from_slice(&params.priority.to_be_bytes());
    out.extend_from_slice(&params.reliability_param().to_be_bytes());
    out.extend_from_slice(&(params.label.len() as u16).to_be_bytes());
    out.extend_from_slice(&(params.protocol.len() as u16).to_be_bytes());
    out.extend_from_slice(params.label.as_bytes());
    out.extend_from_slice(params.protocol.as_bytes());
    out
}

pub fn decode_open(data: &[u8]) -> Option<ChannelParams> {
    if data.len() < 12 || data[0] != MSG_OPEN {
        return None;
    }
    let channel_type = data[1];
    let priority = u16::from_be_bytes(data[2..4].try_into().ok()?);
    let reliability_param = u32::from_be_bytes(data[4..8].try_into().ok()?);
    let label_len = u16::from_be_bytes(data[8..10].try_into().ok()?) as usize;
    let proto_len = u16::from_be_bytes(data[10..12].try_into().ok()?) as usize;
    if data.len() < 12 + label_len + proto_len {
        return None;
    }
    let (ordered, reliability) = ChannelParams::from_type(channel_type, reliability_param);
    Some(ChannelParams {
        ordered,
        reliability,
        priority,
        label: String::from_utf8_lossy(&data[12..12 + label_len]).into_owned(),
        protocol: String::from_utf8_lossy(&data[12 + label_len..12 + label_len + proto_len])
            .into_owned(),
    })
}

pub fn encode_ack() -> Vec<u8> {
    vec![MSG_ACK]
}

pub fn is_ack(data: &[u8]) -> bool {
    data.first() == Some(&MSG_ACK)
}
