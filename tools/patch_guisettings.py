#!/usr/bin/env python3
"""Set values in Kodi's guisettings.xml.

Only run this while Kodi is STOPPED - Kodi holds settings in memory and writes
them out on change/exit, so it will happily clobber edits made underneath it.

Two details matter, both learned the hard way:

  * A setting carrying `default="true"` is treated by Kodi as "use the built-in
    default" and its stored text is ignored. The attribute must be removed or
    the edit silently does nothing.
  * Settings may appear as `<setting id="x">v</setting>` or self-closing
    (`<setting id="x" />`) when empty, so both forms need handling.

We rewrite only the matched lines rather than re-serialising the document, to
avoid reformatting a file Kodi owns.

Usage:
    patch_guisettings.py <path> <setting-id>=<value> [<setting-id>=<value> ...]

Prints one line per setting describing what happened; exits non-zero if any
requested setting could not be found.
"""

import re
import sys
from xml.sax.saxutils import escape


def patch(text, setting_id, value):
    """Return (new_text, changed, found) for a single setting."""
    pattern = re.compile(
        r'(?P<indent>[ \t]*)<setting\s+id="%s"(?P<attrs>[^>]*?)'
        r'(?:/>|>(?P<value>.*?)</setting>)' % re.escape(setting_id),
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        return text, False, False

    current = match.group("value")
    had_default = 'default="true"' in (match.group("attrs") or "")
    if current == value and not had_default:
        return text, False, True

    replacement = '%s<setting id="%s">%s</setting>' % (
        match.group("indent"),
        setting_id,
        escape(value),
    )
    return text[: match.start()] + replacement + text[match.end() :], True, True


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    original = text
    missing = []
    for assignment in sys.argv[2:]:
        setting_id, _, value = assignment.partition("=")
        text, changed, found = patch(text, setting_id, value)
        if not found:
            missing.append(setting_id)
            print("missing  %s" % setting_id)
        elif changed:
            print("set      %s = %s" % (setting_id, value))
        else:
            print("ok       %s already = %s" % (setting_id, value))

    if text != original:
        # Write via a temp file in the same directory so a crash can't leave
        # Kodi with a truncated settings file.
        temp = path + ".deskpad-tmp"
        with open(temp, "w", encoding="utf-8") as handle:
            handle.write(text)
        import os

        os.replace(temp, path)

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
