// Self-check for DeskPad/Backend/Kodi/KodiProtocol.swift: the guisettings.xml
// editor and Kodi's unframed JSON stream splitter. No Kodi needed.
//
//   cp tools/kodi_protocol_check.swift /tmp/main.swift &&
//   swiftc -o /tmp/kodi_protocol_check DeskPad/Backend/Kodi/KodiProtocol.swift /tmp/main.swift &&
//   /tmp/kodi_protocol_check
//
// (Copied to main.swift because only that file may hold top-level code.)

import Foundation

let settings = """
<settings version="2">
    <setting id="videoscreen.monitor" default="true">Default</setting>
    <setting id="videoscreen.screenmode">WINDOW</setting>
    <setting id="videoscreen.blankdisplays" />
</settings>
"""

/// A default="true" setting must lose the attribute, or Kodi ignores the value.
let patched = GuiSettings.patched(settings, "videoscreen.monitor", to: "DeskPad Dev Display (46)")!
assert(patched.contains(#"    <setting id="videoscreen.monitor">DeskPad Dev Display (46)</setting>"#), patched)
assert(!patched.contains(#"default="true""#))
assert(GuiSettings.read(patched, "videoscreen.monitor") == "DeskPad Dev Display (46)")

/// Self-closing form, escaping round-trip, missing ids, and a no-op stays a no-op.
let closed = GuiSettings.patched(settings, "videoscreen.blankdisplays", to: "a<b&c")!
assert(closed.contains(#"<setting id="videoscreen.blankdisplays">a&lt;b&amp;c</setting>"#), closed)
assert(GuiSettings.read(closed, "videoscreen.blankdisplays") == "a<b&c")
assert(GuiSettings.read(settings, "videoscreen.blankdisplays") == "")
assert(GuiSettings.read(settings, "nope") == nil)
assert(GuiSettings.patched(settings, "nope", to: "x") == nil)
assert(GuiSettings.patched(settings, "videoscreen.screenmode", to: "WINDOW") == settings)
// Similar ids must not match each other.
assert(GuiSettings.read(settings, "videoscreen.screen") == nil)

/// apply() writes atomically and reports what it could not find.
let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("guisettings-check.xml")
try! settings.write(to: file, atomically: true, encoding: .utf8)
assert(GuiSettings.apply([("videoscreen.screenmode", "1920x1080p(1920x1080)")], to: file) == nil)
assert(GuiSettings.read(try! String(contentsOf: file, encoding: .utf8), "videoscreen.screenmode") == "1920x1080p(1920x1080)")
assert(GuiSettings.apply([("missing.id", "x")], to: file) != nil)
try? FileManager.default.removeItem(at: file)

// The stream splitter: notifications ahead of the reply, braces inside strings,
// escaped quotes, and an object that has not fully arrived yet.
let stream = Data(#"{"method":"Player.OnPlay","params":{"x":"}{"}}  {"id":"a","result":"q\"}"}{"id":"#.utf8)
let (first, rest) = KodiRPC.splitFirstObject(stream)!
assert(String(decoding: first, as: UTF8.self) == #"{"method":"Player.OnPlay","params":{"x":"}{"}}"#)
let (second, tail) = KodiRPC.splitFirstObject(rest)!
assert(String(decoding: second, as: UTF8.self) == #"{"id":"a","result":"q\"}"}"#)
assert(KodiRPC.splitFirstObject(tail) == nil)

print("all checks passed")
