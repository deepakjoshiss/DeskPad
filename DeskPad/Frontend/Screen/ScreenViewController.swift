import Cocoa
import IOSurface
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

/// The mirrored virtual display. Reports pointer and keyboard input so the
/// controller can forward it to whatever app is on the virtual display.
///
/// The two kinds of input are deliberately on different gestures. A *single*
/// click is DeskPad's own: it focuses the mirror and starts forwarding
/// keystrokes, without touching the virtual display - so the mirror can be used
/// as a keyboard remote without the pointer being taken away. A *double* click
/// hands the pointer over instead.
class ScreenView: NSView {
    var onCaptureMouse: ((NSPoint) -> Void)?
    var onClick: ((NSPoint, CGMouseButton, Int) -> Void)?
    var onScroll: ((NSPoint, CGFloat, CGFloat) -> Void)?
    var onKey: ((UInt16, String?, NSEvent.ModifierFlags) -> Void)?

    /// Deliver the click that also activates DeskPad, rather than swallowing it,
    /// so the double click that hands the pointer over is not eaten by window
    /// activation when DeskPad is inactive.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        return true
    }

    /// The window is movable by its background, so AppKit would start a window
    /// drag on mouse-down here. Forwarding a click warps the cursor onto the
    /// virtual display, and the dragged window follows it - landing DeskPad's
    /// own window on the display it is mirroring, where it appears to vanish.
    /// The titlebar still moves the window.
    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    /// Keystrokes only arrive at a view that can hold focus.
    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        updateKeyboardIndicator()
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateKeyboardIndicator()
        return true
    }

    /// The indicator also has to follow window activation, since keystrokes only
    /// reach the first responder of the *key* window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(updateKeyboardIndicator),
                name: name,
                object: window
            )
        }
        updateKeyboardIndicator()
    }

    /// Forwarding keystrokes is otherwise invisible - and so is not forwarding
    /// them - so the mirror gets a border while it is acting as the keyboard.
    @objc private func updateKeyboardIndicator() {
        let isForwarding = window?.isKeyWindow == true && window?.firstResponder === self
        layer?.borderWidth = isForwarding ? 2 : 0
        layer?.borderColor = NSColor(named: "TitleBarActive")?.cgColor
    }

    /// A single click takes focus and touches the virtual display not at all. A
    /// double click hands the *pointer* over: the cursor jumps to the matching
    /// spot on the virtual display and stays there, so from that moment the
    /// physical mouse is simply on that screen and real clicks and drags land
    /// natively. Nothing is clicked on the user's behalf.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard event.clickCount >= 2 else {
            return
        }
        onCaptureMouse?(convert(event.locationInWindow, from: nil))
    }

    /// Right click still synthesises a click, since there is no equivalent of
    /// "hand the pointer over" for it - the context menu has to be asked for.
    override func rightMouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), .right, event.clickCount)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(
            convert(event.locationInWindow, from: nil),
            event.scrollingDeltaY,
            event.scrollingDeltaX
        )
    }

    /// Deliberately does not call `super`: NSView's implementation beeps at every
    /// key it cannot handle, and this view handles none of them itself.
    ///
    /// Only key-down is forwarded. Kodi's channel takes a whole button press at a
    /// time, and the injection path posts its own down/up pair, so a separate
    /// key-up would double every keystroke. Held keys still repeat, because macOS
    /// sends repeats as further key-down events.
    override func keyDown(with event: NSEvent) {
        onKey?(event.keyCode, event.charactersIgnoringModifiers, event.modifierFlags)
    }

    override func keyUp(with _: NSEvent) {}

    /// Modifiers ride along on each key-down, so a bare modifier press has
    /// nothing to forward - but it must still be swallowed rather than beep.
    override func flagsChanged(with _: NSEvent) {}
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        let screenView = ScreenView()
        screenView.wantsLayer = true
        screenView.onCaptureMouse = { [weak self] point in
            guard let point = self?.displayPoint(from: point) else {
                return
            }
            store.dispatch(MouseLocationAction.requestCursorCapture(atPoint: point))
        }
        screenView.onClick = { [weak self] point, button, clickCount in
            guard let point = self?.displayPoint(from: point) else {
                return
            }
            store.dispatch(MouseLocationAction.requestClick(
                atPoint: point,
                button: button,
                clickCount: clickCount
            ))
        }
        screenView.onScroll = { [weak self] point, deltaY, deltaX in
            guard let point = self?.displayPoint(from: point) else {
                return
            }
            store.dispatch(MouseLocationAction.requestScroll(
                atPoint: point,
                deltaY: deltaY,
                deltaX: deltaX
            ))
        }
        screenView.onKey = { keyCode, characters, modifiers in
            store.dispatch(KeyboardInputAction.requestKey(
                keyCode: keyCode,
                characters: characters,
                modifiers: modifiers
            ))
        }
        view = screenView
    }

    /// Start out forwarding keystrokes, so the mirror is a working keyboard as
    /// soon as the window is focused - by launching it, or by tabbing back to it,
    /// not only by clicking the mirror.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    private var display: CGVirtualDisplay!
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "DeskPad Dev Display"
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        // Distinct serial from the release build (0x0001): macOS refuses to create
        // two virtual displays sharing a vendor/product/serial identity, and this
        // triple is what the display's stable UUID is derived from.
        descriptor.serialNum = 0x0002

        let display = CGVirtualDisplay(descriptor: descriptor)
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            // 16:9 (default)
            CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
            // 32:9
            CGVirtualDisplayMode(width: 5120, height: 1440, refreshRate: 60),
            // 21:9 (239:100, 12:5)
            CGVirtualDisplayMode(width: 5120, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 3840, height: 1600, refreshRate: 60),
            CGVirtualDisplayMode(width: 3440, height: 1440, refreshRate: 60),
            // 16:9
            CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60),
            CGVirtualDisplayMode(width: 1600, height: 900, refreshRate: 60),
            CGVirtualDisplayMode(width: 1366, height: 768, refreshRate: 60),
            CGVirtualDisplayMode(width: 1280, height: 720, refreshRate: 60),
            // 16:10
            CGVirtualDisplayMode(width: 2560, height: 1600, refreshRate: 60),
            CGVirtualDisplayMode(width: 1920, height: 1200, refreshRate: 60),
            CGVirtualDisplayMode(width: 1680, height: 1050, refreshRate: 60),
            CGVirtualDisplayMode(width: 1440, height: 900, refreshRate: 60),
            CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60),
        ]
        display.apply(settings)

        // Reordering settings.modes does not control which mode macOS picks on
        // attach - it chooses one itself (and may restore a stored preference).
        // Force the launch resolution explicitly once the display registers.
        applyPreferredMode(to: display.displayID, width: 1920, height: 1080, attemptsRemaining: 20)
    }

    /// Switches `displayID` to the given 1x mode, retrying until the virtual
    /// display has published its mode list.
    private func applyPreferredMode(
        to displayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        attemptsRemaining: Int
    ) {
        let mode = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode])?
            .first { $0.width == width && $0.height == height && $0.pixelWidth == width }

        guard let mode else {
            guard attemptsRemaining > 0 else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.applyPreferredMode(
                    to: displayID,
                    width: width,
                    height: height,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success else {
            return
        }
        CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil)
        CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted {
                view.window?.orderFrontRegardless()
            }
        }

        if
            viewData.resolution != .zero,
            viewData.resolution != previousResolution
            || viewData.scaleFactor != previousScaleFactor
        {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor
            stream = nil
            view.window?.contentAspectRatio = viewData.resolution
            // The captured IOSurface carries no colour space of its own, so
            // CoreAnimation applies its own assumption when compositing it -
            // measured as roughly a gamma-1.8 decode, which lifts blacks and
            // washes the picture out. Frames arrive in the display's colour
            // space (CGDisplayStream's documented default), so tagging the
            // surface with that same space means no conversion happens at all
            // and the mirror stays correct whichever profile the display is
            // assigned. Do not "fix" this by forcing a colour space on either
            // the stream or the display profile: a mismatched display profile
            // only cancels part of the error and hides it.
            let displayColorSpace = CGDisplayCopyColorSpace(display.displayID)
            let displayColorSpaceProperties = displayColorSpace.copyPropertyList()
            let stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: Int(viewData.resolution.width * viewData.scaleFactor),
                outputHeight: Int(viewData.resolution.height * viewData.scaleFactor),
                pixelFormat: 1_111_970_369,
                properties: [
                    CGDisplayStream.showCursor: true,
                ] as CFDictionary,
                queue: .main,
                handler: { [weak self] _, _, frameSurface, _ in
                    if let surface = frameSurface {
                        if let properties = displayColorSpaceProperties {
                            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, properties)
                        }
                        self?.view.layer?.contents = surface
                    }
                }
            )
            self.stream = stream
            stream?.start()
        }
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard
            let screenResolution = previousResolution,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    /// Maps a point in the mirrored view onto the virtual display's own
    /// coordinate space (top-left origin, in points), or nil if the display
    /// resolution isn't known yet.
    private func displayPoint(from viewPoint: NSPoint) -> NSPoint? {
        guard
            let screenResolution = previousResolution,
            view.frame.width > 0,
            view.frame.height > 0
        else {
            return nil
        }
        return NSPoint(
            x: viewPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - viewPoint.y) / view.frame.height * screenResolution.height
        )
    }
}
