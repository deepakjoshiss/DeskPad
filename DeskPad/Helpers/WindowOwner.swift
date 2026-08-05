import Cocoa

/// The pid owning the topmost ordinary window whose frame satisfies `predicate`,
/// ignoring DeskPad's own windows.
///
/// Both input paths need this, for different reasons. A forwarded click has to
/// know which app to activate; a forwarded keystroke carries no coordinates at
/// all, so the only way to address it is "whoever owns the mirrored display".
func topmostWindowOwner(where predicate: (CGRect) -> Bool) -> pid_t? {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []

    // The list is front-to-back, so the first hit is the topmost window.
    for window in windows {
        guard
            (window[kCGWindowLayer as String] as? Int) == 0,
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"],
            let width = bounds["Width"], let height = bounds["Height"],
            predicate(CGRect(x: x, y: y, width: width, height: height)),
            let pid = window[kCGWindowOwnerPID as String] as? pid_t,
            pid != ProcessInfo.processInfo.processIdentifier
        else {
            continue
        }
        return pid
    }
    return nil
}
