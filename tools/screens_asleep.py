#!/usr/bin/env python3
"""Report whether the physical screens are asleep.

The teardown watcher needs this because display sleep takes DeskPad's *virtual*
display out of CoreGraphics' list as well, which is indistinguishable from
DeskPad having exited. Measured 2026-09-06: the screen went off at 13:12:52 and
the watcher declared "DeskPad's display has gone" at 13:12:57, tearing down a
session whose DeskPad ran for another 15 hours.

IODisplayWrangler's CurrentPowerState - the usual answer - does not exist on
Apple Silicon, where the property set is empty. CGDisplayIsAsleep on the main
display does work, and matches the ctypes-against-CoreGraphics approach the rest
of the launcher's tools already take.

Usage:
    screens_asleep.py

Exit codes:
    0  the screens are asleep
    1  the screens are awake (or the state could not be determined)
"""

import ctypes
import ctypes.util
import sys


def load_core_graphics():
    path = ctypes.util.find_library("CoreGraphics") or (
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    )
    return ctypes.cdll.LoadLibrary(path)


def main():
    try:
        core_graphics = load_core_graphics()
    except OSError as exc:
        print(f"screens_asleep: {exc}", file=sys.stderr)
        return 1

    main_display = core_graphics.CGMainDisplayID()
    asleep = core_graphics.CGDisplayIsAsleep(main_display)
    print("asleep" if asleep else "awake")
    return 0 if asleep else 1


if __name__ == "__main__":
    sys.exit(main())
