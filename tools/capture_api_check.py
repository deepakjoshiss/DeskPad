#!/usr/bin/env python3
"""Exercises DeskPad's capture API against the running app. See API.md.

Doubles as the reference Python client: `request()` is all a caller needs.
Run it from an app that is already allowed, or answer the first-use prompt.
"""
import json
import os
import socket
import struct
import sys
import tempfile
import time

SOCK = os.path.expanduser("~/Library/Application Support/DeskPad Dev/api.sock")


def request(req, sock_path=SOCK):
    """One request per connection: a JSON line out; a JSON header line and `len` bytes back."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
        while True:
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            data += chunk
    line, _, payload = data.partition(b"\n")
    header = json.loads(line)
    assert len(payload) == header["len"], (len(payload), header)
    return header, payload


def png_size_and_profile(png):
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    w, h = struct.unpack(">II", png[16:24])
    # sRGB is tagged with PNG's own sRGB chunk; any other space with an ICC profile.
    return w, h, b"sRGB" in png[:200] or b"iCCP" in png[:200]


def main():
    status, _ = request({"op": "status"})
    print("status", status)
    assert status["ok"], status

    header, png = request({"op": "screenshot"})
    print("screenshot", header)
    assert header["ok"], header
    w, h, has_profile = png_size_and_profile(png)
    assert (w, h) == (header["w"], header["h"]) == (status["w"], status["h"]), "unscaled size must be native"
    assert has_profile, "the PNG must be tagged with its colour space"

    header, png = request({"op": "screenshot", "max_width": 960})
    assert header["ok"] and header["w"] == 960 and png_size_and_profile(png)[0] == 960, header
    header, _ = request({"op": "screenshot", "max_width": 100000})
    assert header["ok"] and header["w"] == w, "must never upscale"

    # A frame newer than "now" only arrives if something on screen changes.
    t0 = time.time() * 1000
    started = time.time()
    header, _ = request({"op": "screenshot", "after_t": t0 + 60_000, "timeout_ms": 300})
    assert not header["ok"] and header["error"] == "timeout" and header["len"] == 0, header
    assert 0.25 < time.time() - started < 2, "after_t must wait out timeout_ms"
    assert header["t"] is not None

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "shot.png")
        header, payload = request({"op": "screenshot", "path": path})
        assert header["ok"] and header["path"] == path and payload == b"", header
        assert png_size_and_profile(open(path, "rb").read())[:2] == (w, h)
        header, _ = request({"op": "screenshot", "path": path})
        assert header["error"] == "bad_path", "must never overwrite"
        for bad in ("relative.png", os.path.join(tmp, "x.jpg"), os.path.join(tmp, "missing", "x.png")):
            assert request({"op": "screenshot", "path": bad})[0]["error"] == "bad_path", bad
        os.symlink(os.path.join(tmp, "target.png"), os.path.join(tmp, "link.png"))
        assert request({"op": "screenshot", "path": os.path.join(tmp, "link.png")})[0]["error"] == "bad_path"

        assert request({"op": "nope"})[0]["error"] == "bad_request"
        assert request({"op": "screenshot", "max_width": 0})[0]["error"] == "bad_request"
        assert request({"op": "record_stop"})[0]["error"] == "not_recording"

        movie = os.path.join(tmp, "run.mov")
        header, _ = request({"op": "record_start", "path": movie, "max_width": 1280, "max_seconds": 30})
        assert header["ok"] and header["path"] == movie, header
        assert request({"op": "record_start"})[0]["error"] == "busy"
        time.sleep(2)
        header, _ = request({"op": "record_stop"})
        print("record_stop", header)
        assert header["ok"] and header["path"] == movie and header["duration"] > 1, header
        assert open(movie, "rb").read(12)[4:8] == b"ftyp", "the movie must be finalised"

    print("all checks passed")


if __name__ == "__main__":
    sys.exit(main())
