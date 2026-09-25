import AVFoundation
import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Stream plumbing shared with the mirror

/// Receives frames from ScreenCaptureKit and hands each complete one on, with the
/// mach time at which it was displayed.
///
/// A separate object because `SCStreamOutput` and `SCStreamDelegate` are
/// Objective-C protocols whose callbacks arrive off the main thread, which is
/// exactly what a main-actor view controller should not be conforming to.
final class DisplayCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (CVPixelBuffer, UInt64) -> Void
    private let onStop: (SCStream, Error) -> Void

    init(onFrame: @escaping (CVPixelBuffer, UInt64) -> Void, onStop: @escaping (SCStream, Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
        super.init()
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard
            type == .screen,
            let info = completeFrameInfo(sampleBuffer),
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }
        onFrame(pixelBuffer, info[.displayTime] as? UInt64 ?? mach_absolute_time())
    }

    /// ScreenCaptureKit keeps delivering frames while the display is unchanged,
    /// marked `.idle` and carrying no new pixels - CGDisplayStream simply sent
    /// nothing in that situation. Handing an idle frame to the layer is what
    /// produces an intermittently black mirror, so only `.complete` is used.
    private func completeFrameInfo(_ sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let rawStatus = info[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete
        else {
            return nil
        }
        return info
    }

    /// Reports *which* stream stopped, because a stop is not by itself news: a
    /// stream this controller already replaced can report its own teardown long
    /// after something healthy took its place. Only the owner knows which
    /// stream is the live one, so it decides what the stop means.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(stream, error)
    }
}

func displayStreamConfiguration(
    pixelWidth: Int,
    pixelHeight: Int,
    displayID: CGDirectDisplayID,
    showsCursor: Bool
) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = pixelWidth
    configuration.height = pixelHeight
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = showsCursor
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
func shareableDisplay(matching displayID: CGDirectDisplayID) async -> SCDisplay? {
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

// MARK: - Errors

/// Every way a capture can fail, each with a stable code a caller can switch on.
/// The point is that nothing ever comes back as an empty image that looks like
/// success.
struct CaptureError: Error, Sendable {
    let code: String
    let message: String

    static let noFrameYet = CaptureError(code: "no_frame_yet", message: "no frame has arrived from the display yet")
    static let displayOff = CaptureError(code: "display_off", message: "the screens are asleep")
    static let timeout = CaptureError(code: "timeout", message: "no newer frame arrived before the timeout")
    static let encodeFailed = CaptureError(code: "encode_failed", message: "the frame could not be encoded as PNG")
    static let busy = CaptureError(code: "busy", message: "a recording is already running")

    static func captureFailed(_ message: String) -> CaptureError {
        CaptureError(code: "capture_failed", message: message)
    }

    static func badPath(_ message: String) -> CaptureError {
        CaptureError(code: "bad_path", message: message)
    }

    static func writeFailed(_ message: String) -> CaptureError {
        CaptureError(code: "write_failed", message: message)
    }

    static func badRequest(_ message: String) -> CaptureError {
        CaptureError(code: "bad_request", message: message)
    }

    static func denied(_ message: String) -> CaptureError {
        CaptureError(code: "denied", message: message)
    }

    static func notRecording(_ message: String) -> CaptureError {
        CaptureError(code: "not_recording", message: message)
    }
}

// MARK: - Latest frame

struct Screenshot {
    let png: Data
    let width: Int
    let height: Int
    /// Epoch milliseconds at which the frame was displayed.
    let t: Double
    let colorSpaceName: String
}

/// The capture stream's latest frame, shared between the capture queue that
/// writes it and the socket threads that wait on it.
///
/// `@unchecked` because every member is only touched under `condition`.
///
/// The stream carries no cursor, so ScreenCaptureKit only marks a frame
/// `.complete` when the display's content actually changed - which makes the
/// frame's timestamp mean "when the screen last changed", and a stale frame
/// recognisable by its old `t`.
final class FrameStore: @unchecked Sendable {
    enum State: Equatable {
        case starting
        case live
        case displayOff
        case failed(String)
    }

    private let condition = NSCondition()
    private var state = State.starting
    private var pixelBuffer: CVPixelBuffer?
    private var t: Double?
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// When the last frame was displayed, kept even once that frame is dropped,
    /// so an error reply can still say how current the caller's view was.
    var latestT: Double? {
        condition.lock()
        defer { condition.unlock() }
        return t
    }

    var colorSpaceName: String {
        condition.lock()
        defer { condition.unlock() }
        return colorSpace.name as String? ?? "unnamed"
    }

    var currentState: State {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    /// A new stream is starting, possibly at a new size or in a new colour space,
    /// so the previous frame no longer describes the display.
    func begin(colorSpace: CGColorSpace) {
        condition.lock()
        state = .starting
        pixelBuffer = nil
        self.colorSpace = colorSpace
        condition.broadcast()
        condition.unlock()
    }

    func publish(_ buffer: CVPixelBuffer, displayTime: UInt64) {
        let t = Self.epochMilliseconds(machTime: displayTime)
        condition.lock()
        pixelBuffer = buffer
        self.t = t
        state = .live
        condition.broadcast()
        condition.unlock()
    }

    /// Drops the frame: a stopped stream's last frame is exactly the stale image
    /// that must never be handed out as current.
    func stop(_ state: State) {
        condition.lock()
        self.state = state
        pixelBuffer = nil
        condition.broadcast()
        condition.unlock()
    }

    /// The latest frame as a PNG, waiting up to `timeout` for one displayed
    /// after `afterT` (or for the first frame at all). Never scales unless asked,
    /// never scales up, and never converts colour: callers read pixel values out
    /// of these images, and both would silently change them.
    func screenshot(maxWidth: Int?, afterT: Double?, timeout: TimeInterval) -> Result<Screenshot, CaptureError> {
        let frame: (CVPixelBuffer, Double, CGColorSpace)
        switch latestFrame(afterT: afterT, timeout: timeout) {
        case let .success(value): frame = value
        case let .failure(error): return .failure(error)
        }
        guard let (png, width, height) = Self.encodePNG(frame.0, colorSpace: frame.2, maxWidth: maxWidth) else {
            return .failure(.encodeFailed)
        }
        return .success(Screenshot(
            png: png,
            width: width,
            height: height,
            t: frame.1,
            colorSpaceName: frame.2.name as String? ?? "unnamed"
        ))
    }

    private func latestFrame(afterT: Double?, timeout: TimeInterval) -> Result<(CVPixelBuffer, Double, CGColorSpace), CaptureError> {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            switch state {
            case .displayOff:
                return .failure(.displayOff)
            case let .failed(message):
                return .failure(.captureFailed(message))
            case .starting, .live:
                break
            }
            if let pixelBuffer, let t, afterT.map({ t > $0 }) ?? true {
                return .success((pixelBuffer, t, colorSpace))
            }
            if !condition.wait(until: deadline) {
                return .failure(pixelBuffer == nil ? .noFrameYet : .timeout)
            }
        }
    }

    /// Copies the pixels out while the buffer is locked: ScreenCaptureKit reuses
    /// its buffers, and an image still pointing into one would change under us.
    private static func encodePNG(
        _ pixelBuffer: CVPixelBuffer,
        colorSpace: CGColorSpace,
        maxWidth: Int?
    ) -> (Data, Int, Int)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = CVPixelBufferGetBaseAddress(pixelBuffer).map { Data(bytes: $0, count: bytesPerRow * height) }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        // BGRA with the alpha byte ignored: the screen is opaque, and dropping
        // alpha keeps the PNG plain RGB.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard
            let pixels,
            let provider = CGDataProvider(data: pixels as CFData),
            var image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        if let maxWidth, maxWidth < width {
            let scaledHeight = max(1, Int((Double(height) * Double(maxWidth) / Double(width)).rounded()))
            // Same colour space as the source, so drawing scales without matching.
            guard let context = CGContext(
                data: nil,
                width: maxWidth,
                height: scaledHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: scaledHeight))
            guard let scaled = context.makeImage() else {
                return nil
            }
            image = scaled
        }

        // ImageIO embeds the image's colour space as the PNG's ICC profile.
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return (png as Data, image.width, image.height)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    /// Mach time counts from boot and is not a wall clock, so it is converted by
    /// its age: the result is on the same clock a caller reads with `Date()`.
    private static func epochMilliseconds(machTime: UInt64) -> Double {
        let now = mach_absolute_time()
        let ageTicks = now > machTime ? now - machTime : 0
        let ageNanoseconds = Double(ageTicks) * Double(timebase.numer) / Double(timebase.denom)
        let t = Date().timeIntervalSince1970 * 1000 - ageNanoseconds / 1_000_000
        return (t * 1000).rounded() / 1000
    }
}

// MARK: - Files

/// Where captures go when nobody names a path.
enum CaptureFolder {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/DeskPad")
    }

    static func newFileURL(extension ext: String) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        var candidate = url.appendingPathComponent("DeskPad \(stamp).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathComponent("DeskPad \(stamp) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}

/// Checks a path a caller asked DeskPad to write to.
///
/// DeskPad is unsandboxed and may hold access to folders the caller does not,
/// so an unchecked path would let a caller write - or overwrite - files through
/// DeskPad that it could not touch itself. Hence: absolute, the expected
/// extension, an existing parent, and nothing there already.
func validateOutputPath(_ path: String, extension ext: String) -> Result<String, CaptureError> {
    guard path.hasPrefix("/") else {
        return .failure(.badPath("the path must be absolute"))
    }
    let url = URL(fileURLWithPath: path)
    guard url.pathExtension.lowercased() == ext else {
        return .failure(.badPath("the path must end in .\(ext)"))
    }
    var isDirectory: ObjCBool = false
    guard
        FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return .failure(.badPath("the parent folder does not exist"))
    }
    var info = stat()
    guard lstat(path, &info) != 0, errno == ENOENT else {
        return .failure(.badPath("something already exists at that path; DeskPad never overwrites"))
    }
    return .success(path)
}

/// Creates the file, refusing to replace anything or to follow a symlink - the
/// check in `validateOutputPath` alone would leave a gap between check and use.
func writeExclusively(_ data: Data, to path: String) -> CaptureError? {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    guard fd >= 0 else {
        let reason = String(cString: strerror(errno))
        return errno == EEXIST ? .badPath("something already exists at that path") : .badPath(reason)
    }
    defer { close(fd) }
    let written = data.withUnsafeBytes { bytes -> Bool in
        var offset = 0
        while offset < bytes.count {
            let result = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                return false
            }
            offset += result
        }
        return true
    }
    guard written else {
        let reason = String(cString: strerror(errno))
        unlink(path)
        return .writeFailed(reason)
    }
    return nil
}

// MARK: - Recording

/// One recording: its own cursorless stream, encoded to HEVC by DeskPad itself.
///
/// Deliberately not `SCRecordingOutput`. That hands the file to macOS's
/// `replayd`, which puts its own Stop button in the menu bar; clicking it ended
/// the recording, deleted the file, and never told DeskPad - which carried on
/// showing "recording" for hours and then reported a file that did not exist.
/// Written here, the file is DeskPad's to finish, and every way a recording
/// can end reaches DeskPad.
///
/// `@unchecked` because the writer and everything about its progress is only
/// touched on `queue`, which is also where frames arrive.
final class RecordingSession: @unchecked Sendable {
    let url: URL
    /// The identity of the app that started it; nil when started from
    /// DeskPad's own menu.
    let owner: String?
    let startedAt = Date()
    /// Called on `queue` when the recording ends by itself, with what happened
    /// to the file.
    var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.jellyvin.deskpad.recording")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var stream: SCStream?
    private var output: DisplayCaptureOutput?
    private var lastFrameTime: CMTime?
    private var isFinishing = false
    /// nil until finished; then nil inside for success, or why it failed.
    private var finishResult: String??
    private var finishWaiters: [(String?) -> Void] = []

    init(url: URL, owner: String?, width: Int, height: Int) throws {
        self.url = url
        self.owner = owner
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // HEVC rather than H.264, whose 4096-pixel limit the 5120-wide modes exceed.
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
    }

    func start(display: SCDisplay, configuration: SCStreamConfiguration) async throws {
        let output = DisplayCaptureOutput { [weak self] pixelBuffer, displayTime in
            self?.append(pixelBuffer, displayTime: displayTime)
        } onStop: { [weak self] _, error in
            self?.queue.async {
                self?.streamDidStop(error)
            }
        }
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: output
        )
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    /// Stops capturing and finishes the file. Returns nil once the movie is
    /// complete on disk, or why it is not.
    func finish() async -> String? {
        try? await stream?.stopCapture()
        return await withCheckedContinuation { continuation in
            queue.async {
                self.finalize { continuation.resume(returning: $0) }
            }
        }
    }

    /// Only frames with new content arrive, so the movie is variable frame rate:
    /// a still screen simply holds its last frame. Timestamps are the frames'
    /// own display times, so the pacing is real.
    private func append(_ pixelBuffer: CVPixelBuffer, displayTime: UInt64) {
        guard !isFinishing else {
            return
        }
        let time = CMClockMakeHostTimeFromSystemUnits(displayTime)
        if let lastFrameTime {
            guard time > lastFrameTime else {
                return
            }
        } else {
            guard writer.startWriting() else {
                fail("could not start writing the movie: \(writer.error?.localizedDescription ?? "unknown error")")
                return
            }
            writer.startSession(atSourceTime: time)
        }
        // A real-time input that is not ready is an encoder falling behind;
        // dropping the frame is the only option that keeps up.
        guard input.isReadyForMoreMediaData else {
            return
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            fail("the movie encoder failed: \(writer.error?.localizedDescription ?? "unknown error")")
            return
        }
        lastFrameTime = time
    }

    /// Display sleep and the like stop the stream. Whatever was recorded until
    /// then is still finished and kept.
    private func streamDidStop(_ error: Error) {
        fail("screen capture stopped: \(error.localizedDescription)")
    }

    private func fail(_ reason: String) {
        guard !isFinishing else {
            return
        }
        finalize { [weak self] saveError in
            guard let self else {
                return
            }
            let kept = saveError == nil ? "what was recorded until then is saved" : "nothing could be saved (\(saveError!))"
            onFailure?("the recording to \(url.path) ended by itself - \(reason); \(kept)")
        }
    }

    /// On `queue`. Safe to reach twice - a failure and a stop can race - and
    /// every caller hears the one outcome.
    private func finalize(_ done: @escaping (String?) -> Void) {
        if let finishResult {
            done(finishResult)
            return
        }
        finishWaiters.append(done)
        guard !isFinishing else {
            return
        }
        isFinishing = true

        guard lastFrameTime != nil, writer.status == .writing else {
            writer.cancelWriting()
            complete("no frames were recorded")
            return
        }
        input.markAsFinished()
        // To now, not to the last frame, so a recording that ends on a still
        // screen lasts as long as it actually ran.
        writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
        writer.finishWriting { [self] in
            queue.async { [self] in
                complete(writer.status == .completed
                    ? nil
                    : "the movie could not be finished: \(writer.error?.localizedDescription ?? "unknown error")")
            }
        }
    }

    private func complete(_ result: String?) {
        finishResult = .some(result)
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0(result) }
    }
}

// MARK: - Service

/// Screenshots and recordings of the virtual display, for the menu and the
/// socket API alike.
///
/// Runs its own capture stream, separate from the mirror's: the mirror has to
/// show the cursor, and captures must not contain it.
@MainActor
final class CaptureService {
    let frames = FrameStore()

    private(set) var recording: RecordingSession?
    /// Why the last recording ended by itself, so a later stop can say so
    /// instead of a bare "nothing is recording".
    private var lastRecordingFailure: String?
    private var isStartingRecording = false
    var onRecordingChange: (() -> Void)?

    private let model: AppModel
    private var stream: SCStream?
    private var captureOutput: DisplayCaptureOutput?
    private var streamTask: Task<Void, Never>?
    private let captureQueue = DispatchQueue(label: "com.jellyvin.deskpad.api-capture")
    private var areScreensAsleep = false
    private var observers: [any NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        observeModel()
        observeScreenSleep()
        restartStream()
    }

    /// Also how a failed stream is retried: the API calls this when a request
    /// finds capture down.
    func restartStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.rebuildStream()
        }
    }

    private func rebuildStream() async {
        if let stream {
            self.stream = nil
            captureOutput = nil
            try? await stream.stopCapture()
        }
        guard
            !Task.isCancelled,
            !areScreensAsleep,
            let displayID = model.displayID,
            model.resolution != .zero
        else {
            return
        }
        let configuration = displayStreamConfiguration(
            pixelWidth: Int(model.resolution.width * model.scaleFactor),
            pixelHeight: Int(model.resolution.height * model.scaleFactor),
            displayID: displayID,
            showsCursor: false
        )
        // The latest frame is held indefinitely, taking one buffer out of the
        // pool; the default depth of 3 would leave the stream short.
        configuration.queueDepth = 5
        frames.begin(colorSpace: CGColorSpace(name: configuration.colorSpaceName) ?? CGColorSpace(name: CGColorSpace.sRGB)!)

        guard let display = await shareableDisplay(matching: displayID) else {
            frames.stop(.failed("the virtual display is not in ScreenCaptureKit's inventory"))
            return
        }
        guard !Task.isCancelled else {
            return
        }

        let frames = frames
        let output = DisplayCaptureOutput { pixelBuffer, displayTime in
            frames.publish(pixelBuffer, displayTime: displayTime)
        } onStop: { [weak self] stoppedStream, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.streamDidStop(stoppedStream, error: error)
                }
            }
        }
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: output
        )
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
        } catch {
            logDiagnostic("could not start the capture API's stream: \(error)")
            frames.stop(.failed("could not start screen capture: \(error.localizedDescription). "
                    + "Check DeskPad's Screen Recording permission."))
            return
        }
        guard !Task.isCancelled else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        captureOutput = output
    }

    /// Display sleep takes the virtual display out of ScreenCaptureKit's
    /// inventory and stops the stream; that is `display_off`, and recovers on
    /// wake. Anything else is a real failure, retried on the next request.
    private func streamDidStop(_ stoppedStream: SCStream, error: Error) {
        guard stoppedStream === stream else {
            return
        }
        stream = nil
        captureOutput = nil
        if areScreensAsleep {
            frames.stop(.displayOff)
        } else {
            logDiagnostic("the capture API's stream stopped: \(error)")
            frames.stop(.failed("screen capture stopped: \(error.localizedDescription)"))
        }
    }

    /// Re-arms after every change, because `withObservationTracking` reports one;
    /// the handler runs before the new value is stored, hence the async hop.
    private func observeModel() {
        withObservationTracking {
            _ = model.displayID
            _ = model.resolution
            _ = model.scaleFactor
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.restartStream()
                    self?.observeModel()
                }
            }
        }
    }

    private func observeScreenSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.areScreensAsleep = true
                self?.frames.stop(.displayOff)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.areScreensAsleep = false
                self?.restartStream()
            }
        })
    }

    var status: [String: Any] {
        [
            "w": Int(model.resolution.width * model.scaleFactor),
            "h": Int(model.resolution.height * model.scaleFactor),
            "scale": Double(model.scaleFactor),
            "colorspace": frames.colorSpaceName,
            "recording": recording != nil,
            "recording_path": recording?.url.path ?? NSNull(),
        ]
    }

    /// `maxWidth` scales down only; `maxSeconds` nil means no cap, which only the
    /// menu uses - the red menu bar icon is the user's reminder to stop.
    func startRecording(
        to url: URL,
        maxWidth: Int?,
        maxSeconds: Int?,
        owner: String?
    ) async -> Result<URL, CaptureError> {
        guard recording == nil, !isStartingRecording else {
            return .failure(.busy)
        }
        guard !areScreensAsleep else {
            return .failure(.displayOff)
        }
        guard let displayID = model.displayID, model.resolution != .zero else {
            return .failure(.noFrameYet)
        }
        isStartingRecording = true
        defer { isStartingRecording = false }

        guard let display = await shareableDisplay(matching: displayID) else {
            return .failure(.captureFailed("the virtual display is not in ScreenCaptureKit's inventory"))
        }

        var width = Int(model.resolution.width * model.scaleFactor)
        var height = Int(model.resolution.height * model.scaleFactor)
        if let maxWidth, maxWidth < width {
            height = Int((Double(height) * Double(maxWidth) / Double(width)).rounded())
            width = maxWidth
        }
        // Video encoders want even dimensions.
        width &= ~1
        height &= ~1
        let configuration = displayStreamConfiguration(
            pixelWidth: width,
            pixelHeight: height,
            displayID: displayID,
            showsCursor: false
        )
        configuration.scalesToFit = true

        let session: RecordingSession
        do {
            session = try RecordingSession(url: url, owner: owner, width: width, height: height)
            session.onFailure = { [weak self, weak session] message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.recordingDidFail(session, message: message)
                    }
                }
            }
            try await session.start(display: display, configuration: configuration)
        } catch {
            return .failure(.captureFailed("could not start recording: \(error.localizedDescription)"))
        }

        recording = session
        lastRecordingFailure = nil
        onRecordingChange?()

        if let maxSeconds {
            Task { [weak self, weak session] in
                try? await Task.sleep(for: .seconds(maxSeconds))
                guard let self, let session, recording === session else {
                    return
                }
                logDiagnostic("recording to \(session.url.path) reached its \(maxSeconds)s cap; stopping it.")
                _ = await stopRecording(by: nil)
            }
        }
        return .success(url)
    }

    /// `caller` nil is the user, who may stop anything; an app may only stop a
    /// recording it started.
    func stopRecording(by caller: String?) async -> Result<(URL, Double), CaptureError> {
        guard let session = recording else {
            return .failure(.notRecording(lastRecordingFailure ?? "nothing is recording"))
        }
        if let caller, session.owner != caller {
            return .failure(.denied("this recording was started by another app or from DeskPad's menu"))
        }
        recording = nil
        onRecordingChange?()

        if let failure = await session.finish() {
            logDiagnostic("the recording to \(session.url.path) could not be saved: \(failure)")
            return .failure(.captureFailed(failure))
        }
        // Belt and braces: "finished" is not taken as "saved" until the file is
        // actually there.
        guard FileManager.default.fileExists(atPath: session.url.path) else {
            logDiagnostic("the recording to \(session.url.path) stopped, but the file is gone.")
            return .failure(.captureFailed("the recording ended but no file exists at \(session.url.path)"))
        }
        let duration = await (try? AVURLAsset(url: session.url).load(.duration).seconds) ?? 0
        return .success((session.url, duration))
    }

    private func recordingDidFail(_ session: RecordingSession?, message: String) {
        guard let session, recording === session else {
            return
        }
        recording = nil
        lastRecordingFailure = message
        logDiagnostic(message)
        onRecordingChange?()
    }
}
