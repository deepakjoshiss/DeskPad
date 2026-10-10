#!/usr/bin/env python3
"""Minimal Kodi JSON-RPC client over Kodi's raw TCP socket (default port 9090).

Kodi's TCP transport is a stream that may interleave notifications with
responses and never closes, so we incrementally decode objects and return the
one whose id matches our request.

Usage:
    kodi_rpc.py <method> [json-params]

Exit codes:
    0  got a result (printed as JSON to stdout)
    1  transport failure (Kodi not listening / timed out)
    2  Kodi returned a JSON-RPC error
"""

import json
import socket
import sys

HOST = "127.0.0.1"
PORT = 9090
TIMEOUT = 6.0
REQUEST_ID = "vindesk-launcher"


def call(method, params=None):
    request = {"jsonrpc": "2.0", "id": REQUEST_ID, "method": method}
    if params is not None:
        request["params"] = params

    try:
        sock = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
    except OSError as exc:
        raise TransportError(f"cannot connect to Kodi on {HOST}:{PORT}: {exc}")

    with sock:
        sock.sendall(json.dumps(request).encode())
        decoder = json.JSONDecoder()
        buffer = ""
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                raise TransportError("timed out waiting for a response")
            if not chunk:
                raise TransportError("connection closed before a response arrived")
            buffer += chunk.decode("utf-8", "replace")

            # Pull off as many complete objects as the buffer holds; Kodi may
            # push notifications ahead of the response we asked for.
            while buffer:
                buffer = buffer.lstrip()
                if not buffer:
                    break
                try:
                    message, end = decoder.raw_decode(buffer)
                except ValueError:
                    break  # partial object, need more bytes
                buffer = buffer[end:]
                if message.get("id") == REQUEST_ID:
                    return message


class TransportError(RuntimeError):
    pass


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1

    method = sys.argv[1]
    params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else None

    try:
        message = call(method, params)
    except TransportError as exc:
        print(f"kodi_rpc: {exc}", file=sys.stderr)
        return 1

    if "error" in message:
        print(json.dumps(message["error"]), file=sys.stderr)
        return 2

    print(json.dumps(message.get("result")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
