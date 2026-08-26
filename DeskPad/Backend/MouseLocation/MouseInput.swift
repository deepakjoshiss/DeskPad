import Cocoa

/// Hands the pointer over to the virtual display without clicking anything.
///
/// `displayPoint` is in the display's own coordinate space; the translation to
/// the global space CGEvent uses happens here.
func captureCursor(onDisplay displayID: CGDirectDisplayID, at displayPoint: NSPoint) {
    captureCursor(at: globalPoint(on: displayID, displayPoint: displayPoint))
}

func forwardClick(
    onDisplay displayID: CGDirectDisplayID,
    at displayPoint: NSPoint,
    button: CGMouseButton,
    clickCount: Int
) {
    postClick(
        at: globalPoint(on: displayID, displayPoint: displayPoint),
        button: button,
        clickCount: clickCount
    )
}

func forwardScroll(
    onDisplay displayID: CGDirectDisplayID,
    at displayPoint: NSPoint,
    deltaY: CGFloat,
    deltaX: CGFloat
) {
    postScroll(
        at: globalPoint(on: displayID, displayPoint: displayPoint),
        deltaY: deltaY,
        deltaX: deltaX
    )
}

/// Converts a point in a display's own coordinate space to the global space that
/// CGEvent uses. `CGDisplayBounds` is already top-left-origin and y-down, which
/// matches both the incoming point and CGEvent, so this is just a translation.
private func globalPoint(on displayID: CGDirectDisplayID, displayPoint: NSPoint) -> CGPoint {
    let bounds = CGDisplayBounds(displayID)
    return CGPoint(x: bounds.origin.x + displayPoint.x, y: bounds.origin.y + displayPoint.y)
}

/// Synthetic events are paced on their own queue: posting move/down/up in one
/// tight burst gets dropped by apps that sample input on a frame boundary (Kodi
/// and other SDL apps especially), which showed up as clicks needing two
/// attempts. Off the main thread so the pacing never stalls the mirror.
private let injectionQueue = DispatchQueue(label: "com.jellyvin.deskpad.input-injection")

/// Gap between synthetic events. Long enough for the receiving app to sample
/// each one, short enough to stay imperceptible.
private let interEventDelay: UInt32 = 15000

/// Brings the app owning the window at `point` to the front.
///
/// Clicking the mirror makes DeskPad the active app, so the app being mirrored
/// is left inactive and spends the forwarded click on activating itself instead
/// of acting on it. Activating first means the click does what was intended -
/// and hands keyboard focus over as a bonus.
private func activateApplicationOwningWindow(at point: CGPoint) {
    guard let pid = topmostWindowOwner(where: { $0.contains(point) }) else {
        return
    }
    NSRunningApplication(processIdentifier: pid)?.activate()
}

/// Hands the pointer over to the virtual display without clicking anything.
///
/// From here the physical mouse is simply on that display, so clicks and drags
/// are the real thing rather than synthesised approximations of one.
///
/// The mirrored app is activated as well, because clicking the mirror made
/// DeskPad the active app and left the mirrored one inactive - so the first real
/// click after the pointer arrives would be spent activating it rather than
/// acting on what was clicked. That is exactly the cost this gesture exists to
/// avoid. The trade is that keyboard forwarding stops, since DeskPad is no longer
/// frontmost; keystrokes then reach the mirrored app natively, and a single click
/// on the mirror takes the keyboard back.
private func captureCursor(at point: CGPoint) {
    activateApplicationOwningWindow(at: point)
    injectionQueue.async {
        moveCursor(to: point)
    }
}

/// Moves the cursor onto the virtual display and synthesises a full click there.
///
/// Both halves matter. Warping alone leaves the target app unaware the pointer
/// moved, so it handles the click at its own stale position; posting alone would
/// leave the cursor behind on the mirror, desyncing hover state and drag origins
/// from where the click landed.
private func postClick(at point: CGPoint, button: CGMouseButton, clickCount: Int) {
    let types: (down: CGEventType, up: CGEventType) = button == .right
        ? (.rightMouseDown, .rightMouseUp)
        : (.leftMouseDown, .leftMouseUp)

    activateApplicationOwningWindow(at: point)

    injectionQueue.async {
        moveCursor(to: point)
        usleep(interEventDelay)

        for type in [types.down, types.up] {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
            ) else {
                continue
            }
            // Carries double/triple clicks through. Without it every click reads
            // as a single one and double-click-to-open never fires.
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
            event.post(tap: .cghidEventTap)
            usleep(interEventDelay)
        }
    }
}

private func postScroll(at point: CGPoint, deltaY: CGFloat, deltaX: CGFloat) {
    injectionQueue.async {
        moveCursor(to: point)
        usleep(interEventDelay)

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(deltaY.rounded())),
            wheel2: Int32(clamping: Int(deltaX.rounded())),
            wheel3: 0
        ) else {
            return
        }
        // Scroll events are delivered by location, so it has to be set
        // explicitly - unlike mouse events, the constructor takes no position.
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

/// Moves the cursor to `point` *and* tells the rest of the system it moved.
///
/// `CGWarpMouseCursorPosition` is documented not to generate any events, so on
/// its own the app under the cursor never learns the pointer moved and handles
/// the following click at its own stale pointer position - the click is
/// delivered, just somewhere else. Posting an explicit mouse-moved event is what
/// keeps the receiving app's idea of the cursor in sync with ours.
private func moveCursor(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cghidEventTap)
}
