# Interop harness: the Python echo client over stdio. Prints one line
# per call shape to stderr (stdout carries frames) and exits non-zero
# on any failure. Mirrors go/examples/echo_client_stdio.
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import grpcdc
import echo_grpc_dc
from echo_pb import EchoRequest
from stdio import StdioTransport


def req(message, count=0):
    return EchoRequest(message=message, count=count)


def main():
    transport = StdioTransport(sys.stdout.buffer, sys.stdin.buffer)
    client = echo_grpc_dc.EchoClient(grpcdc.Channel(transport))

    unary = client.Unary(req("hello"))
    print(f"unary={unary.message}", file=sys.stderr)

    ticks = [f"{r.message}#{r.index}" for r in client.ServerStream(req("tick", 3))]
    print(f"server_stream={','.join(ticks)}", file=sys.stderr)

    joined = client.ClientStream([req("a"), req("b"), req("c")])
    print(f"client_stream={joined.message}", file=sys.stderr)

    echoed = [r.message for r in client.Bidi([req("x"), req("y")])]
    print(f"bidi={','.join(echoed)}", file=sys.stderr)

    md = client.Unary(req("hello"), metadata={"x-echo": "meta"})
    print(f"metadata={md.message}", file=sys.stderr)

    try:
        client.Unary(EchoRequest(message="slow", delay_ms=400), timeout=0.05)
        print("deadline=no error", file=sys.stderr)
    except grpcdc.StatusError as e:
        print(f"deadline={e.code}", file=sys.stderr)

    try:
        client.Unary(req("fail"))
        print("error_case=no error", file=sys.stderr)
        sys.exit(1)
    except grpcdc.StatusError as e:
        print(f"error_case={e}", file=sys.stderr)


if __name__ == "__main__":
    main()
