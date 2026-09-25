import Cocoa
import CoreVideo
import Observation
import ScreenCaptureKit

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
        true
    }

    /// The window is movable by its background, so AppKit would start a window
    /// drag on mouse-down here. Forwarding a click warps the cursor onto the
    /// virtual display, and the dragged window follows it - landing DeskPad's
    /// own window on the display it is mirroring, where it appears to vanish.
    /// The titlebar still moves the window.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// Keystrokes only arrive at a view that can hold focus.
    override var acceptsFirstResponder: Bool {
        true
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
        // viewDidMoveToWindow can fire repeatedly - including with a nil window -
        // and each call used to add another pair of observers that nothing ever
        // removed.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
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

/// What macOS - and Kodi's monitor list - calls the virtual display.
let virtualDisplayName = "DeskPad Dev Display"

class ScreenViewController: NSViewController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("ScreenViewController is built in code, never loaded from a nib.")
    }

    override func loadView() {
        let screenView = ScreenView()
        screenView.wantsLayer = true
        screenView.onCaptureMouse = { [weak self] point in
            guard let self, let displayID = model.displayID, let point = displayPoint(from: point) else {
                return
            }
            captureCursor(onDisplay: displayID, at: point)
        }
        screenView.onClick = { [weak self] point, button, clickCount in
            guard let self, let displayID = model.displayID, let point = displayPoint(from: point) else {
                return
            }
            forwardClick(onDisplay: displayID, at: point, button: button, clickCount: clickCount)
        }
        screenView.onScroll = { [weak self] point, deltaY, deltaX in
            guard let self, let displayID = model.displayID, let point = displayPoint(from: point) else {
                return
            }
            forwardScroll(onDisplay: displayID, at: point, deltaY: deltaY, deltaX: deltaX)
        }
        screenView.onKey = { [weak self] keyCode, characters, modifiers in
            guard let displayID = self?.model.displayID else {
                return
            }
            forwardKey(onDisplay: displayID, keyCode: keyCode, characters: characters, modifiers: modifiers)
        }

        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        errorOverlay.onReload = { [weak self] in
            self?.reloadCapture()
        }
        screenView.addSubview(errorOverlay)
        // Fixed width so the message wraps to a predictable shape, but never wider
        // than the mirror - which the user is free to resize down to a sliver.
        let overlayWidth = errorOverlay.widthAnchor.constraint(equalToConstant: 380)
        overlayWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            errorOverlay.centerXAnchor.constraint(equalTo: screenView.centerXAnchor),
            errorOverlay.centerYAnchor.constraint(equalTo: screenView.centerYAnchor),
            overlayWidth,
            errorOverlay.widthAnchor.constraint(
                lessThanOrEqualTo: screenView.widthAnchor,
                multiplier: 0.9
            ),
        ])

        view = screenView
    }

    /// Start out forwarding keystrokes, so the mirror is a working keyboard as
    /// soon as the window is focused - by launching it, or by tabbing back to it,
    /// not only by clicking the mirror.
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        // The window exists by now, which it may not have at viewDidLoad.
        applyModel()
    }

    private let errorOverlay = CaptureErrorOverlay()
    /// Whether the physical screens are off. A capture stop means something quite
    /// different either side of this.
    private var areScreensAsleep = false
    private var screensDidSleepObserver: (any NSObjectProtocol)?
    private var screensDidWakeObserver: (any NSObjectProtocol)?
    private var display: CGVirtualDisplay?
    private var stream: SCStream?
    private var captureOutput: DisplayCaptureOutput?
    private var captureTask: Task<Void, Never>?
    /// Frames are decoded off the main thread; only the layer assignment hops
    /// back onto it. CGDisplayStream ran its handler on the main queue outright.
    private let captureQueue = DispatchQueue(label: "com.jellyvin.deskpad.capture")
    private var isWindowHighlighted = false
    /// What the live stream was built for, so a redundant geometry change does
    /// not tear a perfectly good stream down and rebuild it.
    private var capturedResolution: CGSize?
    private var capturedScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = virtualDisplayName
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
        model.virtualDisplayDidAppear(display.displayID)
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

        observeScreenSleep()
        observeModel()
        applyModel()
    }

    /// Screen sleep and wake come from NSWorkspace's own centre, not the default
    /// one - they are not posted to the default centre at all.
    private func observeScreenSleep() {
        let center = NSWorkspace.shared.notificationCenter
        screensDidSleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.areScreensAsleep = true
            }
        }
        screensDidWakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.areScreensAsleep = false
                self.recoverIfCaptureIsDown()
            }
        }
    }

    /// Re-arms after every change, because `withObservationTracking` reports one.
    ///
    /// The change handler runs *before* the new value is stored, so reading the
    /// model has to wait for the next turn of the run loop; reading it inline
    /// would see the old value every time.
    private func observeModel() {
        withObservationTracking {
            _ = model.resolution
            _ = model.scaleFactor
            _ = model.isPointerWithinScreen
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyModel()
                    self?.observeModel()
                }
            }
        }
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

    private func applyModel() {
        if model.isPointerWithinScreen != isWindowHighlighted {
            isWindowHighlighted = model.isPointerWithinScreen
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted {
                view.window?.orderFrontRegardless()
            }
        }

        guard model.resolution != .zero else {
            return
        }

        // Outside the guard below, and repeated on every pass: the first pass
        // runs from viewDidLoad, where there is not necessarily a window yet.
        // Applying this only alongside a capture restart would let that first
        // pass consume the change and leave the aspect ratio never set.
        view.window?.contentAspectRatio = model.resolution

        if model.resolution != capturedResolution || model.scaleFactor != capturedScaleFactor {
            capturedResolution = model.resolution
            capturedScaleFactor = model.scaleFactor
            startCapture(
                pixelWidth: Int(model.resolution.width * model.scaleFactor),
                pixelHeight: Int(model.resolution.height * model.scaleFactor)
            )
        }
    }

    /// Restarts the mirror at a new pixel size.
    ///
    /// Every resolution change tears the stream down and builds a new one, because
    /// SCStreamConfiguration is applied at construction. Cancelling the previous
    /// task first means a burst of rapid changes settles on the last one rather
    /// than racing several half-built streams against each other.
    private func startCapture(pixelWidth: Int, pixelHeight: Int) {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            await self?.restartCapture(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
    }

    private func restartCapture(pixelWidth: Int, pixelHeight: Int) async {
        if let stream {
            self.stream = nil
            captureOutput = nil
            try? await stream.stopCapture()
        }
        guard !Task.isCancelled, let displayID = display?.displayID else {
            return
        }
        guard let capturedDisplay = await shareableDisplay(matching: displayID) else {
            logDiagnostic("the virtual display never appeared in ScreenCaptureKit's "
                + "inventory; the mirror will stay blank.")
            presentCaptureError("The virtual display did not appear in ScreenCaptureKit's inventory.")
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let output = DisplayCaptureOutput { [weak self] pixelBuffer, _ in
            guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.view.layer?.contents = surface
                    // A frame actually landing is the only proof the mirror is live
                    // again, so that - rather than a stream merely having started -
                    // is what takes the panel down.
                    self.errorOverlay.dismiss()
                }
            }
        } onStop: { [weak self] stoppedStream, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.captureDidStop(stoppedStream, error: error)
                }
            }
        }
        let stream = SCStream(
            filter: SCContentFilter(display: capturedDisplay, excludingWindows: []),
            configuration: displayStreamConfiguration(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                displayID: displayID,
                showsCursor: true
            ),
            delegate: output
        )
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            logDiagnostic("could not start screen capture: \(error). Check that DeskPad "
                + "still holds Screen Recording permission in System Settings > Privacy & Security.")
            presentCaptureError("\(error.localizedDescription). Check that DeskPad still holds "
                + "Screen Recording permission in System Settings > Privacy & Security.")
            return
        }
        guard !Task.isCancelled else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        captureOutput = output
        // This attempt is over even though the panel stays up until a frame lands,
        // so the button goes live again rather than sticking on "Reloading..."
        // forever if the new stream starts but never delivers anything.
        errorOverlay.setReloading(false)
    }

    /// Decides what a stopped stream actually means.
    ///
    /// Display sleep is the common case and is *not* a failure. Turning the screen
    /// off takes the virtual display out of ScreenCaptureKit's inventory, which
    /// arrives here as a stop - measured as `-3815`, to the second, against
    /// pmset's "Display is turned off". It resolves itself on wake, so putting the
    /// reload panel up for it cries wolf: worse, the layer keeps its last frame,
    /// so the user wakes to a mirror that looks perfectly fine with an error panel
    /// sitting on top of it. That is the false alarm this guards against.
    private func captureDidStop(_ stoppedStream: SCStream, error: Error) {
        // A stream that has already been replaced says nothing about the mirror
        // the user is looking at. Only the live one is worth reacting to.
        guard stoppedStream === stream else {
            return
        }
        stream = nil
        captureOutput = nil

        guard !areScreensAsleep else {
            logDiagnostic("screen capture stopped while the screens were asleep: "
                + "\(error). Recovering on wake rather than asking the user.")
            return
        }
        logDiagnostic("screen capture stopped: \(error). Offering a reload on the mirror.")
        presentCaptureError("\(error.localizedDescription).")
    }

    /// Waking is the moment the virtual display comes back, so it is the moment to
    /// rebuild - otherwise the mirror stays frozen on the frame it had when the
    /// screen went off, which is indistinguishable from a working one.
    private func recoverIfCaptureIsDown() {
        guard stream == nil else {
            return
        }
        reloadCapture()
    }

    /// Rebuilds the stream at the display's *current* geometry, which is not
    /// necessarily what the dead stream was built for - a reload may be happening
    /// precisely because the display changed underneath it.
    ///
    /// `capturedResolution` and `capturedScaleFactor` are updated in step so that
    /// the next `applyModel` still recognises a genuine later geometry change
    /// instead of mistaking it for the size this reload already covered.
    private func reloadCapture() {
        guard model.resolution != .zero else {
            presentCaptureError("The virtual display has not published a resolution yet.")
            return
        }
        errorOverlay.setReloading(true)
        capturedResolution = model.resolution
        capturedScaleFactor = model.scaleFactor
        startCapture(
            pixelWidth: Int(model.resolution.width * model.scaleFactor),
            pixelHeight: Int(model.resolution.height * model.scaleFactor)
        )
    }

    private func presentCaptureError(_ message: String) {
        errorOverlay.present(message: message)
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let screenResolution = model.resolution
        guard
            screenResolution != .zero,
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
        let screenResolution = model.resolution
        guard
            screenResolution != .zero,
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
