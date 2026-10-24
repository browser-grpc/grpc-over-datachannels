//! Userspace TCP proof: a TCP echo roundtrip where BOTH
//! endpoints are smoltcp stacks linked by a virtual Ethernet
//! pair. No OS sockets anywhere: smoltcp terminates the TCP
//! handshake, data, and teardown in userspace.

use grpc_dc_tcp_sidecar::PairDevice;
use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, IpAddress, IpCidr, Ipv4Address};

fn iface(mac: u8, ip: Ipv4Address, device: &mut PairDevice, now: Instant) -> Interface {
    let mut iface = Interface::new(
        Config::new(EthernetAddress([0x02, 0, 0, 0, 0, mac]).into()),
        device,
        now,
    );
    iface.update_ip_addrs(|addrs| {
        addrs.push(IpCidr::new(IpAddress::Ipv4(ip), 24)).unwrap();
    });
    iface
}

fn tcp_socket() -> tcp::Socket<'static> {
    tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; 4096]),
        tcp::SocketBuffer::new(vec![0; 4096]),
    )
}

#[test]
fn smoltcp_tcp_echo_zero_os_sockets() {
    let (mut dev_a, mut dev_b) = PairDevice::pair();
    let ip_a = Ipv4Address::new(10, 0, 0, 1);
    let ip_b = Ipv4Address::new(10, 0, 0, 2);
    let mut now = Instant::from_millis(0);
    let mut iface_a = iface(1, ip_a, &mut dev_a, now);
    let mut iface_b = iface(2, ip_b, &mut dev_b, now);

    let mut sockets_a = SocketSet::new(vec![]);
    let mut sockets_b = SocketSet::new(vec![]);
    let server = sockets_a.add(tcp_socket());
    let client = sockets_b.add(tcp_socket());

    let payload = b"hello over userspace tcp";
    let mut echoed: Vec<u8> = Vec::new();
    let mut listening = false;
    let mut connecting = false;
    let mut sent = false;

    for _ in 0..10_000 {
        now += smoltcp::time::Duration::from_millis(1);
        iface_a.poll(now, &mut dev_a, &mut sockets_a);
        iface_b.poll(now, &mut dev_b, &mut sockets_b);

        {
            let server_sock = sockets_a.get_mut::<tcp::Socket>(server);
            if !listening {
                server_sock.listen(80).unwrap();
                listening = true;
            }
            if server_sock.can_recv() {
                let data = server_sock.recv(|buf| (buf.len(), buf.to_vec())).unwrap();
                if server_sock.can_send() && !data.is_empty() {
                    server_sock.send_slice(&data).unwrap();
                }
            }
        }
        {
            let client_sock = sockets_b.get_mut::<tcp::Socket>(client);
            if !connecting {
                let cx = iface_b.context();
                client_sock.connect(cx, (ip_a, 80), 49_152).unwrap();
                connecting = true;
            }
            if client_sock.can_send() && !sent {
                client_sock.send_slice(payload).unwrap();
                sent = true;
            }
            if client_sock.can_recv() {
                echoed = client_sock.recv(|buf| (buf.len(), buf.to_vec())).unwrap();
            }
        }
        if echoed == payload {
            break;
        }
    }
    assert_eq!(echoed, payload, "TCP echo through two smoltcp stacks");
}
