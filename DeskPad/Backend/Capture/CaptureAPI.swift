import Cocoa
import Security

/// The capture API: one JSON request line per connection on a Unix socket,
/// answered with one JSON header line and then exactly `len` bytes. See API.md.
///
/// A Unix socket rather than localhost TCP because the kernel tells us who is on
/// the other end (`LOCAL_PEERTOKEN`), which is what the allowlist is built on -
/// and because nothing outside this user, browsers included, can reach it.
///
/// This matters more than usual: DeskPad holds the Screen Recording grant, so
/// the API hands callers screen contents macOS would otherwise make them ask
/// the user for. The first-use prompt stands in for that question.
///
/// `@unchecked` because its own state is immutable after `start()`; everything
/// mutable lives behind `FrameStore`'s lock, `approvalLock`, or the main actor.
final class CaptureAPI: @unchecked Sendable {
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeskPad Dev/api.sock")
    }

    private let service: CaptureService
    private let kodi: KodiLauncher
    private let frames: FrameStore
    private let window: NSWindow
    /// One prompt at a time, so a second request from the same app waits for the
    /// first answer instead of stacking a second, identical prompt.
    private let approvalLock = NSLock()

    @MainActor
    init(service: CaptureService, kodi: KodiLauncher, window: NSWindow) {
        self.service = service
        self.kodi = kodi
        frames = service.frames
        self.window = window
    }

    // MARK: Socket

    func start() {
        let path = Self.socketURL.path
        let directory = Self.socketURL.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        chmod(directory, 0o700)

        // A socket file left by a crash is harmless to remove; one another
        // running DeskPad is still answering on is not.
        if isAnswering(path) {
            logDiagnostic("another DeskPad is already serving \(path); the capture API is off in this one.")
            return
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logDiagnostic("capture API: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        let bound = withUnixAddress(path) { bind(fd, $0, $1) } ?? -1
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            logDiagnostic("capture API: could not listen on \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        Thread.detachNewThread { [self] in
            acceptLoop(fd)
        }
    }

    private func isAnswering(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        return withUnixAddress(path) { connect(fd, $0, $1) } == 0
    }

    private func withUnixAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED {
                    continue
                }
                logDiagnostic("capture API: accept() failed, API stopped: \(String(cString: strerror(errno)))")
                return
            }
            // Requests can block for a while - on the first-use prompt, or
            // waiting out `after_t` - so each gets its own thread.
            DispatchQueue.global().async { [self] in
                handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        // A caller that hangs up early must not take DeskPad down with SIGPIPE.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var readTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        let reply: Reply = if let line = readLine(client) {
            respond(to: line, from: client)
        } else {
            .failure(.badRequest("expected one JSON request line"))
        }
        send(reply, to: client)
    }

    private func readLine(_ fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < 65536 {
            let count = read(fd, &byte, 1)
            if count < 0, errno == EINTR {
                continue
            }
            guard count == 1 else {
                return line.isEmpty ? nil : line
            }
            if byte == UInt8(ascii: "\n") {
                return line
            }
            line.append(byte)
        }
        return nil
    }

    private func send(_ reply: Reply, to fd: Int32) {
        var header = reply.header
        header["len"] = reply.payload.count
        if header["t"] == nil {
            header["t"] = frames.latestT ?? NSNull()
        }
        guard var data = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        data.append(UInt8(ascii: "\n"))
        data.append(reply.payload)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                offset += written
            }
        }
    }

    // MARK: Requests

    private struct Request: Decodable {
        let op: String
        let maxWidth: Int?
        let path: String?
        let afterT: Double?
        let timeoutMs: Int?
        let maxSeconds: Int?
    }

    private struct Reply {
        var header: [String: Any]
        var payload = Data()

        static func failure(_ error: CaptureError) -> Reply {
            Reply(header: ["ok": false, "error": error.code, "message": error.message])
        }
    }

    private func respond(to line: Data, from client: Int32) -> Reply {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let request = try? decoder.decode(Request.self, from: line) else {
            return .failure(.badRequest("the request line is not a JSON object with an \"op\""))
        }
        guard ["screenshot", "record_start", "record_stop", "status", "kodi_launch"].contains(request.op) else {
            return .failure(.badRequest("unknown op \"\(request.op)\""))
        }
        if let maxWidth = request.maxWidth, maxWidth <= 0 {
            return .failure(.badRequest("max_width must be a positive number of pixels"))
        }

        // Before anything else is looked at, paths included: an app that has not
        // been allowed learns nothing but "denied".
        guard let caller = identifyCaller(client) else {
            return .failure(.denied("could not identify the calling app"))
        }
        guard let identity = approve(caller, op: request.op) else {
            return .failure(.denied("\(caller.name) is not allowed to use DeskPad's capture API"))
        }

        switch request.op {
        case "screenshot": return screenshot(request)
        case "record_start": return startRecording(request, owner: identity)
        case "record_stop": return stopRecording(owner: identity)
        case "kodi_launch": return launchKodi()
        default: return Reply(header: ["ok": true].merging(onMain { self.status }) { $1 })
        }
    }

    private func screenshot(_ request: Request) -> Reply {
        var path: String?
        if let requested = request.path {
            switch validateOutputPath(requested, extension: "png") {
            case let .success(valid): path = valid
            case let .failure(error): return .failure(error)
            }
        }
        let timeoutMs = request.timeoutMs ?? 2000
        guard (0 ... 60000).contains(timeoutMs) else {
            return .failure(.badRequest("timeout_ms must be between 0 and 60000"))
        }

        let shot: Screenshot
        switch frames.screenshot(maxWidth: request.maxWidth, afterT: request.afterT, timeout: Double(timeoutMs) / 1000) {
        case let .success(value):
            shot = value
        case let .failure(error):
            if error.code == "capture_failed" {
                DispatchQueue.main.async { [service] in
                    MainActor.assumeIsolated { service.restartStream() }
                }
            }
            return .failure(error)
        }

        var header: [String: Any] = [
            "ok": true, "t": shot.t, "w": shot.width, "h": shot.height, "colorspace": shot.colorSpaceName,
        ]
        guard let path else {
            return Reply(header: header, payload: shot.png)
        }
        if let error = writeExclusively(shot.png, to: path) {
            return .failure(error)
        }
        header["path"] = path
        return Reply(header: header)
    }

    private func startRecording(_ request: Request, owner: String) -> Reply {
        let maxSeconds = request.maxSeconds ?? 600
        guard (1 ... 3600).contains(maxSeconds) else {
            return .failure(.badRequest("max_seconds must be between 1 and 3600"))
        }
        let url: URL
        if let requested = request.path {
            switch validateOutputPath(requested, extension: "mov") {
            case let .success(valid): url = URL(fileURLWithPath: valid)
            case let .failure(error): return .failure(error)
            }
        } else {
            url = CaptureFolder.newFileURL(extension: "mov")
        }
        let maxWidth = request.maxWidth
        let result = onMain {
            await self.service.startRecording(to: url, maxWidth: maxWidth, maxSeconds: maxSeconds, owner: owner)
        }
        switch result {
        case let .success(url): return Reply(header: ["ok": true, "path": url.path])
        case let .failure(error): return .failure(error)
        }
    }

    private func stopRecording(owner: String) -> Reply {
        switch onMain({ await self.service.stopRecording(by: owner) }) {
        case let .success((url, duration)): Reply(header: ["ok": true, "path": url.path, "duration": duration])
        case let .failure(error): .failure(error)
        }
    }

    /// Blocks until Kodi is up on the display - tens of seconds on a cold start -
    /// so the reply says where it ended up rather than merely that it was asked.
    private func launchKodi() -> Reply {
        switch onMain({ await self.kodi.launch() }) {
        case let .success(monitor): Reply(header: ["ok": true, "monitor": monitor])
        case let .failure(error): .failure(error)
        }
    }

    @MainActor
    private var status: [String: Any] {
        service.status.merging([
            "kodi_running": KodiLauncher.isKodiRunning,
            "kodi_launching": kodi.isLaunching,
        ]) { $1 }
    }

    /// Runs main-actor work from a request thread and waits for it. These are
    /// GCD threads, not Swift's cooperative pool, so blocking one is fine.
    private func onMain<T>(_ body: @escaping @Sendable @MainActor () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { @MainActor in
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    // MARK: Callers

    struct Caller {
        let name: String
        let path: String
        let code: SecCode
        /// The requirement the caller's own signature declares: what "Always
        /// Allow" stores. Never compared as a string to grant access - a
        /// self-signed binary can declare any requirement it likes - only
        /// checked against with `SecCodeCheckValidity`.
        let requirement: String
    }

    /// Who is really asking.
    ///
    /// The process on the socket is often just a tool - `nc`, a shell, Python -
    /// run by whoever actually wants the picture: an agent, an editor, a script
    /// host. So the walk goes up the parent chain past everything Apple-signed to
    /// the first process that is not. When everything up to launchd is Apple's
    /// (a script typed into Terminal), the topmost process - Terminal - answers.
    ///
    /// Only the immediate peer is identified race-free, by audit token; parents
    /// are looked up by pid. ponytail: a pid can be reused between lookup and
    /// check - acceptable for same-user callers; if that matters, compare each
    /// parent's start time from `kinfo_proc` too.
    private func identifyCaller(_ fd: Int32) -> Caller? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            return nil
        }
        var pid: pid_t = 0
        length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else {
            return nil
        }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        guard var code = Self.guestCode([kSecGuestAttributeAudit: tokenData]) else {
            return nil
        }
        while Self.isAppleSigned(code) {
            let parent = Self.parentPID(of: pid)
            guard parent > 1, let parentCode = Self.guestCode([kSecGuestAttributePid: parent]) else {
                break
            }
            pid = parent
            code = parentCode
        }

        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var requirementString: CFString?
        var url: CFURL?
        guard
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode,
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
            let requirement,
            SecRequirementCopyString(requirement, [], &requirementString) == errSecSuccess,
            let requirementString
        else {
            logDiagnostic("capture API: pid \(pid) has no usable code signature; refusing it.")
            return nil
        }
        SecCodeCopyPath(staticCode, [], &url)
        let path = (url as URL?)?.path ?? "pid \(pid)"
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? (url as URL?)?.deletingPathExtension().lastPathComponent
            ?? path
        return Caller(name: name, path: path, code: code, requirement: requirementString as String)
    }

    private static func guestCode(_ attributes: [CFString: Any]) -> SecCode? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private nonisolated(unsafe) static let appleRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        return requirement
    }()

    private static func isAppleSigned(_ code: SecCode) -> Bool {
        guard let appleRequirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], appleRequirement) == errSecSuccess
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return 0
        }
        return info.kp_eproc.e_ppid
    }

    // MARK: Approval

    /// The identity the caller was allowed under - the stored requirement it
    /// satisfies, or its own after a prompt - or nil when it is not allowed.
    private func approve(_ caller: Caller, op: String) -> String? {
        approvalLock.lock()
        defer { approvalLock.unlock() }
        if let allowed = AllowedApps.requirement(satisfiedBy: caller.code) {
            return allowed
        }
        let (name, path) = (caller.name, caller.path)
        let window = window
        switch onMain({ await Self.prompt(name: name, path: path, op: op, in: window) }) {
        case .deny:
            return nil
        case .once:
            return caller.requirement
        case .always:
            AllowedApps.add(name: caller.name, requirement: caller.requirement)
            return caller.requirement
        }
    }

    private enum Approval: Sendable {
        case deny, once, always
    }

    /// A sheet rather than `runModal`: this runs as main-queue work, and a modal
    /// loop inside main-queue work stalls every other main-queue block - the
    /// mirror's frames included - until it is answered.
    @MainActor
    private static func prompt(name: String, path: String, op: String, in window: NSWindow) async -> Approval {
        let alert = NSAlert()
        alert.messageText = "“\(name)” wants to use DeskPad"
        let asked = op == "kodi_launch" ? "launch Kodi on the DeskPad display" : op.replacingOccurrences(of: "_", with: " ")
        alert.informativeText = """
        \(path)

        It asked to \(asked). Allowing it lets the app use all of DeskPad's API: launching Kodi, and - since \
        DeskPad holds the Screen Recording permission - seeing and recording whatever is on the DeskPad display.
        """
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")

        window.deminiaturize(nil)
        NSApp.activate()
        // Unanswered is denied, and the sheet goes away rather than lingering
        // with an answer nobody is waiting for any more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak alert] in
            MainActor.assumeIsolated {
                if let sheet = alert?.window, window.attachedSheet === sheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
            }
        }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertSecondButtonReturn: return .once
        case .alertThirdButtonReturn: return .always
        default: return .deny
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Apps allowed to use the capture API without asking, by designated
/// requirement - a code-signature identity, not a bundle id, which any app
/// could simply claim.
enum AllowedApps {
    private static let key = "captureAPIAllowedApps"

    static var all: [(name: String, requirement: String)] {
        (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).compactMap {
            guard let name = $0["name"], let requirement = $0["requirement"] else {
                return nil
            }
            return (name, requirement)
        }
    }

    /// Checked against the running code's actual signature, never by comparing
    /// requirement strings.
    static func requirement(satisfiedBy code: SecCode) -> String? {
        all.first { app in
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(app.requirement as CFString, [], &requirement) == errSecSuccess,
                  let requirement
            else {
                return false
            }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }?.requirement
    }

    static func add(name: String, requirement: String) {
        guard !all.contains(where: { $0.requirement == requirement }) else {
            return
        }
        save(all + [(name, requirement)])
    }

    static func remove(requirement: String) {
        save(all.filter { $0.requirement != requirement })
    }

    private static func save(_ apps: [(name: String, requirement: String)]) {
        UserDefaults.standard.set(apps.map { ["name": $0.name, "requirement": $0.requirement] }, forKey: key)
    }
}
