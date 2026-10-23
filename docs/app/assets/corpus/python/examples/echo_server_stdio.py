# Interop harness: the Python echo server over stdio. Other
# languages' tests spawn this and drive it with their client.
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
import echo_grpc_dc
from echo_service import EchoService
from stdio import StdioTransport


def main():
    transport = StdioTransport(sys.stdout.buffer, sys.stdin.buffer)
    # Exit when the driver closes our stdin.
    transport.on_eof = lambda: os._exit(0)
    server = grpcdc.Server()
    echo_grpc_dc.register_echo_server(server, EchoService())
    server.serve_transport(transport)
    import threading

    threading.Event().wait()


if __name__ == "__main__":
    main()
