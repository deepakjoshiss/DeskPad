import Cocoa

/// Forwards a keystroke to whatever app is showing on the mirrored display.
///
/// A keystroke carries no coordinates, so the target is whoever owns the display
/// being mirrored rather than whoever is under the pointer.
func forwardKey(
    onDisplay displayID: CGDirectDisplayID,
    keyCode: UInt16,
    characters: String?,
    modifiers: NSEvent.ModifierFlags
) {
    guard let pid = topmostWindowOwner(where: { $0.intersects(CGDisplayBounds(displayID)) }) else {
        return
    }

    if isKodi(pid) {
        if let button = kodiButtonName(forKeyCode: keyCode, characters: characters) {
            KodiRemote.shared.pressKey(named: button)
        }
        return
    }

    postKey(keyCode: keyCode, characters: characters, modifiers: modifiers, to: pid)
}

/// Kodi's own name for a keyboard button, as its keymap spells it.
///
/// Printable ASCII is passed through as itself - Kodi accepts a single-character
/// button name as that character, which is why keymaps can say `<a>` - so only
/// the keys with no character need a table. Names taken from Kodi's keyboard
/// translator table (visible in the shipped binary); `left`/`right`/`up`/`down`
/// verified end to end against a running Kodi.
private func kodiButtonName(forKeyCode keyCode: UInt16, characters: String?) -> String? {
    if let named = kodiButtonNamesByKeyCode[keyCode] {
        return named
    }
    // Arrow and function keys arrive as private-use scalars rather than text, so
    // anything outside printable ASCII is not a character Kodi can name.
    guard
        let scalar = characters?.lowercased().unicodeScalars.first,
        characters?.unicodeScalars.count == 1,
        (0x20 ... 0x7E).contains(scalar.value)
    else {
        return nil
    }
    return String(scalar)
}

private let kodiButtonNamesByKeyCode: [UInt16: String] = [
    36: "return",
    48: "tab",
    49: "space",
    51: "backspace", // macOS calls it Delete; Kodi means the one that deletes leftwards
    53: "escape",
    76: "kpenter",
    114: "insert",
    115: "home",
    116: "pageup",
    117: "delete", // forward delete
    119: "end",
    121: "pagedown",
    123: "left",
    124: "right",
    125: "down",
    126: "up",
    122: "f1",
    120: "f2",
    99: "f3",
    118: "f4",
    96: "f5",
    97: "f6",
    98: "f7",
    100: "f8",
    101: "f9",
    109: "f10",
    103: "f11",
    111: "f12",
]

/// Injects a key event straight into another process, for mirrored apps that are
/// not Kodi.
///
/// `postToPid` rather than `CGEvent.post`, because a posted key event otherwise
/// goes to the frontmost app - which is VinDesk, so it would come straight back
/// to us. Addressing the process instead is the only way to type into an app that
/// does not hold focus.
///
/// Best-effort by nature: whether it lands depends on how the receiving app reads
/// the keyboard. Apps that watch an NSEvent monitor or an event tap see it while
/// inactive; apps that rely on the responder chain need a key window and will
/// ignore it. Kodi is in the second group, hence its separate JSON-RPC path.
private func postKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, to pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for isKeyDown in [true, false] {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: isKeyDown
        ) else {
            continue
        }
        event.flags = CGEventFlags(modifiers: modifiers)
        // Keeps text input intact for layouts the target would otherwise resolve
        // differently from the raw keycode.
        if let characters, !characters.isEmpty {
            let utf16 = Array(characters.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        event.postToPid(pid)
    }
}

private extension CGEventFlags {
    init(modifiers: NSEvent.ModifierFlags) {
        var flags = CGEventFlags()
        if modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }
        if modifiers.contains(.function) {
            flags.insert(.maskSecondaryFn)
        }
        self = flags
    }
}
