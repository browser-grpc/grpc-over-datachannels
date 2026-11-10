"""Echo server behind a sidecar TCP endpoint, for
sidecar_signaling.test.mjs: accepts framed TCP connections
(one per browser session) and serves generated Echo on each.

Usage: python3 sidecar_echo_server.py <port>
"""

import os
import socket
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python", "examples"))

import grpcdc
import echo_grpc_dc
from echo_service import EchoService


def main():
    port = int(sys.argv[1])
    listen_sock = socket.socket()
    listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listen_sock.bind(("127.0.0.1", port))
    listen_sock.listen(8)
    print(f"READY {port}", flush=True)
    server = grpcdc.Server()
    echo_grpc_dc.register_echo_server(server, EchoService())
    while True:
        conn, _ = listen_sock.accept()
        threading.Thread(
            target=server.serve_transport,
            args=(grpcdc.SidecarTransport.from_socket(conn),),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
