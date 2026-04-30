#!/usr/bin/env python3
"""Simple threaded HTTP server for preview and publish workflows."""

import argparse
from http.server import SimpleHTTPRequestHandler
from socketserver import ThreadingTCPServer


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"


def main():
    parser = argparse.ArgumentParser(description="Serve current directory over HTTP")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    ThreadingTCPServer.allow_reuse_address = True
    with ThreadingTCPServer(("", args.port), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
