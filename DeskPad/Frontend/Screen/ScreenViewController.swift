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

/// Receives frames from ScreenCaptureKit and hands each one's backing IOSurface
/// to the mirror.
///
/// A separate object because `SCStreamOutput` and `SCStreamDelegate` are
/// Objective-C protocols whose callbacks arrive off the main thread, which is
/// exactly what a main-actor view controller should not be conforming to.
private final class DisplayCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (IOSurfaceRef) -> Void

    init(onFrame: @escaping (IOSurfaceRef) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard
            type == .screen,
            isComplete(sampleBuffer),
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else {
            return
        }
        onFrame(surface)
    }

    /// ScreenCaptureKit keeps delivering frames while the display is unchanged,
    /// marked `.idle` and carrying no new pixels - CGDisplayStream simply sent
    /// nothing in that situation. Handing an idle frame to the layer is what
    /// produces an intermittently black mirror, so only `.complete` is used.
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int
        else {
            return false
        }
        return SCFrameStatus(rawValue: rawStatus) == .complete
    }

    /// The stream stopping is otherwise silent - the mirror simply freezes on its
    /// last frame - so it is exactly the kind of failure the diagnostic log is for.
    func stream(_: SCStream, didStopWithError error: Error) {
        logDiagnostic("screen capture stopped: \(error). The mirror is frozen on its last frame.")
    }
}

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

    private var display: CGVirtualDisplay!
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

        observeModel()
        applyModel()
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
        guard let shareableDisplay = await shareableDisplay(matching: displayID) else {
            logDiagnostic("the virtual display never appeared in ScreenCaptureKit's "
                + "inventory; the mirror will stay blank.")
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let output = DisplayCaptureOutput { [weak self] surface in
            DispatchQueue.main.async {
                self?.view.layer?.contents = surface
            }
        }
        let stream = SCStream(
            filter: SCContentFilter(display: shareableDisplay, excludingWindows: []),
            configuration: configuration(pixelWidth: pixelWidth, pixelHeight: pixelHeight, displayID: displayID),
            delegate: output
        )
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            logDiagnostic("could not start screen capture: \(error). Check that DeskPad "
                + "still holds Screen Recording permission in System Settings > Privacy & Security.")
            return
        }
        guard !Task.isCancelled else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        captureOutput = output
    }

    private func configuration(
        pixelWidth: Int,
        pixelHeight: Int,
        displayID: CGDirectDisplayID
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        // The size above is already the display's exact pixel size, so there is
        // nothing to fit; letterboxing here would only ever add error.
        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // Asking for frames in the display's own colour space is what the old
        // CGDisplayStream path got by default (`kCGDisplayStreamColorSpace`
        // "defaults to display color space"), and it is the reason the mirror
        // needs no conversion on the way to the layer. Do not substitute a fixed
        // sRGB here: on a display assigned any other profile that reintroduces
        // exactly the washed-out picture this replaced.
        configuration.colorSpaceName = CGDisplayCopyColorSpace(displayID).name ?? CGColorSpace.sRGB
        return configuration
    }

    /// The virtual display does not show up in ScreenCaptureKit's inventory the
    /// instant it is created, so poll briefly instead of giving up on the first
    /// miss - the same reason `applyPreferredMode` retries.
    private func shareableDisplay(matching displayID: CGDirectDisplayID) async -> SCDisplay? {
        for attempt in 0 ..< 20 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else {
                return nil
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                if let match = content.displays.first(where: { $0.displayID == displayID }) {
                    return match
                }
            } catch {
                logDiagnostic("cannot list shareable content: \(error). DeskPad most likely "
                    + "lacks Screen Recording permission in System Settings > Privacy & Security.")
                return nil
            }
        }
        return nil
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
