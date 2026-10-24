//! Virtual Ethernet pair device for smoltcp: two interfaces
//! cross-connected through in-memory frame queues. The TCP
//! proof built on this (tests/tcp_echo.rs) uses zero OS
//! sockets — smoltcp terminates TCP in userspace on both
//! ends, which is exactly the sidecar shape grpc-dc-proxy
//! needs when the packet transport becomes a DataChannel.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;

pub type FrameQueue = Rc<RefCell<VecDeque<Vec<u8>>>>;

pub fn frame_queue() -> FrameQueue {
    Rc::new(RefCell::new(VecDeque::new()))
}

/// One end of a virtual Ethernet pair. Frames written to
/// `tx` appear in the peer's `rx` queue unchanged.
pub struct PairDevice {
    rx: FrameQueue,
    tx: FrameQueue,
}

impl PairDevice {
    /// Create a connected pair of devices.
    pub fn pair() -> (PairDevice, PairDevice) {
        let a_to_b = frame_queue();
        let b_to_a = frame_queue();
        (
            PairDevice { rx: b_to_a.clone(), tx: a_to_b.clone() },
            PairDevice { rx: a_to_b, tx: b_to_a },
        )
    }

    /// Create a device from explicit queues (used by the
    /// UDP-encapsulated binary to plug its own transport in).
    pub fn from_queues(rx: FrameQueue, tx: FrameQueue) -> PairDevice {
        PairDevice { rx, tx }
    }

    pub fn rx_queue(&self) -> FrameQueue {
        self.rx.clone()
    }

    pub fn tx_queue(&self) -> FrameQueue {
        self.tx.clone()
    }
}

pub struct PairRxToken(Vec<u8>);

impl RxToken for PairRxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.0)
    }
}

pub struct PairTxToken(FrameQueue);

impl TxToken for PairTxToken {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut frame = vec![0u8; len];
        let result = f(&mut frame);
        self.0.borrow_mut().push_back(frame);
        result
    }
}

impl Device for PairDevice {
    type RxToken<'a> = PairRxToken;
    type TxToken<'a> = PairTxToken;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let frame = self.rx.borrow_mut().pop_front()?;
        Some((PairRxToken(frame), PairTxToken(self.tx.clone())))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(PairTxToken(self.tx.clone()))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ethernet;
        caps.max_transmission_unit = 1514;
        caps
    }
}

