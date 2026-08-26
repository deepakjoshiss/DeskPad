import Cocoa
import Observation

/// What the mirror is driven from: which virtual display exists, the geometry
/// macOS has given it, and whether the physical pointer is currently on it.
///
/// `AppDelegate` creates the one instance and hands it to whoever needs it, so
/// there is no global to reach for and no ambiguity about who owns the state.
///
/// Every setter is guarded to assign only on a real change. Observation fires on
/// assignment, not on inequality, so writing the same value would otherwise wake
/// the view controller four times a second for nothing.
@MainActor
@Observable
final class AppModel {
    /// nil until the virtual display has been created.
    private(set) var displayID: CGDirectDisplayID?

    /// The mirrored display's size in points and its backing scale. `.zero`
    /// until macOS has published the display's parameters, which happens a
    /// moment after the display itself appears.
    private(set) var resolution: CGSize = .zero
    private(set) var scaleFactor: CGFloat = 1

    /// Whether the physical pointer is on the mirrored display right now. The
    /// window highlight is the only cue that the pointer has been handed over,
    /// so this drives it.
    private(set) var isPointerWithinScreen = false

    /// Begins watching for display and pointer changes.
    ///
    /// Must be called before the virtual display is created, or the screen
    /// parameters notification announcing it is missed and the mirror never
    /// learns its own resolution.
    func start() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readScreenParameters()
            }
        }

        // Polled rather than event-driven because the question is "which screen
        // contains the pointer", which no single event answers - a global
        // monitor misses moves over DeskPad's own window, and a local one misses
        // everything else.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readPointerLocation()
            }
        }
    }

    /// Called once the virtual display has been created.
    func virtualDisplayDidAppear(_ displayID: CGDirectDisplayID) {
        self.displayID = displayID
        readScreenParameters()
    }

    private var screenParametersObserver: (any NSObjectProtocol)?
    private var pointerTimer: Timer?

    private func readScreenParameters() {
        guard
            let displayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else {
            return
        }
        if resolution != screen.frame.size {
            resolution = screen.frame.size
        }
        if scaleFactor != screen.backingScaleFactor {
            scaleFactor = screen.backingScaleFactor
        }
    }

    private func readPointerLocation() {
        // Unwrapped first: comparing two optionals directly would report the
        // pointer as being on the mirrored display whenever *neither* side has
        // one - before the virtual display exists, `nil == nil` is true.
        guard let displayID else {
            setPointerWithinScreen(false)
            return
        }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
        setPointerWithinScreen(screen?.displayID == displayID)
    }

    private func setPointerWithinScreen(_ isWithin: Bool) {
        if isPointerWithinScreen != isWithin {
            isPointerWithinScreen = isWithin
        }
    }
}
