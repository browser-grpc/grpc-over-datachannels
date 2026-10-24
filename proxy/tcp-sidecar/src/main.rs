//! tcp-sidecar binary: a smoltcp TCP echo listener whose
//! Ethernet frames travel over UDP datagrams (one frame per
//! datagram) to a peer sidecar. The same PairDevice queues
//! accept frames from any transport — a DataChannel carrier
//! is the follow-up; UDP keeps this spike runnable anywhere.
//!
//! Pair two instances:
//!   tcp-sidecar --bind 127.0.0.1:9000 --peer 127.0.0.1:9001 --ip 10.0.0.1
//!   tcp-sidecar --bind 127.0.0.1:9001 --peer 127.0.0.1:9000 --ip 10.0.0.2
//! then TCP-connect to either side's stack via the peer's
//! client tooling (see tests/tcp_echo.rs for the in-process
//! proof; this binary is the deployable shell).

use std::net::UdpSocket;
use std::time::Duration as StdDuration;

use grpc_dc_tcp_sidecar::PairDevice;
use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, Ipv4Address};

fn arg(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}

fn main() {
    let bind = arg("--bind").unwrap_or_else(|| "127.0.0.1:9000".into());
    let peer = arg("--peer").unwrap_or_else(|| "127.0.0.1:9001".into());
    let ip_text = arg("--ip").unwrap_or_else(|| "10.0.0.1".into());
    let ip: Ipv4Address = ip_text.parse().expect("--ip must be an IPv4 address");

    let udp = UdpSocket::bind(&bind).unwrap_or_else(|e| panic!("bind {bind}: {e}"));
    udp.set_read_timeout(Some(StdDuration::from_millis(1))).unwrap();
    udp.connect(&peer).unwrap_or_else(|e| panic!("peer {peer}: {e}"));

    let (mut device, _peer_device) = PairDevice::pair();
    let rx_queue = device.rx_queue();
    let tx_queue = device.tx_queue();

    let mut now = Instant::from_millis(0);
    let mut iface = Interface::new(
        Config::new(EthernetAddress([0x02, 0, 0, 0, 0, ip.octets()[3]]).into()),
        &mut device,
        now,
    );
    iface.update_ip_addrs(|addrs| {
        addrs.push(IpCidr::new(IpAddress::Ipv4(ip), 24)).unwrap();
    });

    let mut sockets = SocketSet::new(vec![]);
    let server = sockets.add(tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; 4096]),
        tcp::SocketBuffer::new(vec![0; 4096]),
    ));
    sockets.get_mut::<tcp::Socket>(server).listen(80).unwrap();
    println!("tcp-sidecar: smoltcp {ip} tcp/80, frames udp {bind} <-> {peer}");

    let mut buf = [0u8; 2048];
    loop {
        // Pump transport: UDP datagrams -> rx queue; tx queue -> UDP.
        while let Ok(n) = udp.recv(&mut buf) {
            rx_queue.borrow_mut().push_back(buf[..n].to_vec());
        }
        now += smoltcp::time::Duration::from_millis(1);
        iface.poll(now, &mut device, &mut sockets);
        while let Some(frame) = tx_queue.borrow_mut().pop_front() {
            // PairDevice already queued the frame for its pair
            // peer; for UDP we intercept the tx queue directly.
            let _ = udp.send(&frame);
        }
        let sock = sockets.get_mut::<tcp::Socket>(server);
        if sock.can_recv() {
            let data = sock.recv(|b| (b.len(), b.to_vec())).unwrap();
            if sock.can_send() && !data.is_empty() {
                sock.send_slice(&data).unwrap();
            }
        }
    }
}
