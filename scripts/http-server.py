#!/usr/bin/env python3
"""Simple threaded HTTP server for preview and publish workflows."""

import argparse
from http.server import SimpleHTTPRequestHandler
from socketserver import ThreadingTCPServer


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        self.send_header(
            "Cache-Control", "no-store, no-cache, must-revalidate, max-age=0"
        )
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser(description="Serve current directory over HTTP")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    ThreadingTCPServer.allow_reuse_address = True
    with ThreadingTCPServer(("", args.port), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
