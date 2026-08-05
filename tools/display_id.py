#!/usr/bin/env python3
"""Print the current CGDirectDisplayID of DeskPad's virtual display.

Identified by its vendor/product/serial triple, which is hardcoded in
ScreenViewController.swift and is also what the display's stable UUID is derived
from. The display ID itself is a volatile per-boot counter and must never be
persisted - look it up fresh every time.

Uses ctypes against CoreGraphics so the launcher stays free of compiled helpers.

Usage:
    display_id.py [vendor] [product] [serial]     # defaults to the dev build's

Exit codes:
    0  found (id printed to stdout)
    1  no matching display attached
"""

import ctypes
import ctypes.util
import sys

MAX_DISPLAYS = 32

# Defaults match DeskPad Dev (serial 0x0002); the release build uses 0x0001.
DEFAULT_VENDOR = 0x3456
DEFAULT_PRODUCT = 0x1234
DEFAULT_SERIAL = 0x0002


def load_core_graphics():
    path = ctypes.util.find_library("CoreGraphics") or (
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    )
    return ctypes.cdll.LoadLibrary(path)


def active_display_ids(core_graphics):
    count = ctypes.c_uint32(0)
    ids = (ctypes.c_uint32 * MAX_DISPLAYS)()
    if core_graphics.CGGetActiveDisplayList(MAX_DISPLAYS, ids, ctypes.byref(count)) != 0:
        raise RuntimeError("CGGetActiveDisplayList failed")
    return list(ids[: count.value])


def main():
    args = sys.argv[1:]
    vendor = int(args[0], 0) if len(args) > 0 else DEFAULT_VENDOR
    product = int(args[1], 0) if len(args) > 1 else DEFAULT_PRODUCT
    serial = int(args[2], 0) if len(args) > 2 else DEFAULT_SERIAL

    try:
        core_graphics = load_core_graphics()
        display_ids = active_display_ids(core_graphics)
    except (OSError, RuntimeError) as exc:
        print(f"display_id: {exc}", file=sys.stderr)
        return 1

    for display_id in display_ids:
        if (
            core_graphics.CGDisplayVendorNumber(display_id) == vendor
            and core_graphics.CGDisplayModelNumber(display_id) == product
            and core_graphics.CGDisplaySerialNumber(display_id) == serial
        ):
            print(display_id)
            return 0

    print(
        "display_id: no display with vendor=0x%X product=0x%X serial=0x%X"
        % (vendor, product, serial),
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
