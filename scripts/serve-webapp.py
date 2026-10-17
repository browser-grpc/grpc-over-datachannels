#!/usr/bin/env python3
"""Serve the built webapp (webapp/dist) with the cross-origin
isolation headers the in-browser Racket/Wasm runner needs:
SharedArrayBuffer requires COOP same-origin + COEP require-corp.

Usage: serve-webapp.py [directory] [port]
"""
import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


if __name__ == "__main__":
    directory = sys.argv[1] if len(sys.argv) > 1 else "webapp/dist"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8006
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", port), functools.partial(Handler, directory=directory)
    )
    print(f"serving {directory} at http://127.0.0.1:{port}/ (COOP/COEP on)")
    server.serve_forever()
