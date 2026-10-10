import Cocoa

/// Starts Kodi on the virtual display, for the menu, the start-up preference
/// and the API alike. Read LAUNCHER.md before changing any of it: every step
/// below exists because its absence broke something that looked like it worked.
///
///   * Kodi's monitor setting is "<display name> (<n>)", where <n> is a
///     volatile per-session number that is not derivable from any CoreGraphics
///     identifier. So it is never computed: Kodi is asked for its own option
///     list, matched on the display name.
///   * Changing `videoscreen.monitor` while Kodi runs wedges Kodi. It is only
///     changed with Kodi stopped, in guisettings.xml, then Kodi is started.
///   * Kodi enumerates displays once, at startup, so the display must exist
///     before Kodi does - which, launched from here, it always does.
///
/// Quitting VinDesk ends the session: `AppDelegate` quits Kodi before the
/// display goes, then calls `finishSession` to put Kodi's display settings back.
/// That restore used to be a watcher script outliving VinDesk, which had to
/// guess from the display vanishing whether VinDesk had quit or the screens had
/// merely slept; VinDesk knows.
@MainActor
final class KodiLauncher {
    /// What the menu shows while a launch runs, and why the last one failed.
    private(set) var progress: String?
    private(set) var lastFailure: String?
    var isLaunching: Bool {
        progress != nil
    }

    var onChange: (() -> Void)?

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    static var isKodiRunning: Bool {
        runningKodi() != nil
    }

    // MARK: Configuration

    private static let guiSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Kodi/userdata/guisettings.xml")

    /// Kodi's display settings from before the session touched them. A file, and
    /// the same one the old launcher script used, so a session that ends without
    /// restoring - VinDesk killed rather than quit - leaves the real values here
    /// for the next session instead of letting it mistake our patched ones for them.
    private static let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VinDesk/pre-session-settings")

    /// Netskope re-signs HTTPS with a private root, and Kodi trusts only its own
    /// bundled roots. `SSL_CERT_FILE` covers Kodi's libcurl and the Python
    /// stdlib; `requests` ignores it and reads `REQUESTS_CA_BUNDLE`, falling back
    /// to `CURL_CA_BUNDLE`, which other add-ons also use. Given to Kodi alone at
    /// launch, rather than to every app via `launchctl setenv` as the script did.
    private static let caBundle = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".certs/kodi-cacert-netskope.pem")

    /// Fullscreen at native 1x 1080p. `defaults write com.jellyvin.deskpad
    /// kodiScreenMode WINDOW` for a plain window instead.
    private var screenMode: String {
        UserDefaults.standard.string(forKey: "kodiScreenMode") ?? "1920x1080p(1920x1080)"
    }

    private static let monitorSetting = "videoscreen.monitor"
    private static let screenModeSetting = "videoscreen.screenmode"

    // MARK: Launch

    /// Brings Kodi up on the virtual display, or confirms it already is. Returns
    /// the monitor Kodi ended up on. One launch at a time: two overlapping runs
    /// race, one stopping the Kodi the other just started.
    func launch() async -> Result<String, CaptureError> {
        guard !isLaunching else {
            return .failure(CaptureError(code: "busy", message: "Kodi is already being launched"))
        }
        lastFailure = nil
        defer { setProgress(nil) }
        do {
            let monitor = try await converge()
            logDiagnostic("Kodi is on '\(monitor)'.")
            return .success(monitor)
        } catch let failure as KodiRPC.Failure {
            lastFailure = failure.message
            logDiagnostic("launching Kodi failed: \(failure.message)")
            return .failure(CaptureError(code: "kodi_failed", message: failure.message))
        } catch {
            lastFailure = error.localizedDescription
            return .failure(CaptureError(code: "kodi_failed", message: error.localizedDescription))
        }
    }

    private func converge() async throws -> String {
        guard FileManager.default.fileExists(atPath: Self.guiSettings.path) else {
            throw KodiRPC.Failure(message: "Kodi's settings file is not at \(Self.guiSettings.path)")
        }
        // Before anything is patched, so there is something true to go back to.
        capturePreSessionSettings()

        setProgress("Waiting for the VinDesk display…")
        let displayID = try await registeredDisplayID()
        let name = virtualDisplayName

        if !Self.isKodiRunning {
            // The fast path: patch before Kodi's first launch so it initialises on
            // the right display in one go. The session number is empirically
            // displayID - 1, but undocumented, so this is strictly a guess - the
            // check below still asks Kodi and corrects it. Never rely on it alone.
            let predicted = "\(name) (\(displayID - 1))"
            if let problem = GuiSettings.apply(
                [(Self.monitorSetting, predicted), (Self.screenModeSetting, screenMode)],
                to: Self.guiSettings
            ) {
                logDiagnostic("could not pre-set Kodi's display (\(problem)); falling back to patch-and-restart.")
            }
            try await startKodi()
        }

        setProgress("Checking Kodi's display…")
        let target = try await monitorOption(named: name)
        if try await currentMonitor() == target {
            return target
        }

        // Stopped for the change: editing it live wedges Kodi.
        setProgress("Moving Kodi to the VinDesk display…")
        await stopKodi()
        if let problem = GuiSettings.apply(
            [(Self.monitorSetting, target), (Self.screenModeSetting, screenMode)],
            to: Self.guiSettings
        ) {
            throw KodiRPC.Failure(message: "could not update Kodi's settings: \(problem)")
        }
        try await startKodi()

        let active = try await currentMonitor()
        guard active == target else {
            // Measured 2026-09-06: Kodi can discard a correct stored monitor about
            // 3s after launch, before it has finished enumerating displays. That
            // is inside Kodi; trying again is the user's call, not a loop here.
            throw KodiRPC.Failure(message: "Kodi reports '\(active)' rather than '\(target)'; it did not "
                + "keep the VinDesk display. Launching again may help.")
        }
        return target
    }

    /// The display is VinDesk's own, so it normally exists already; this waits
    /// out the moment after launch before macOS has published it.
    private func registeredDisplayID() async throws -> CGDirectDisplayID {
        for _ in 0 ..< 100 {
            if let displayID = model.displayID, model.resolution != .zero {
                return displayID
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw KodiRPC.Failure(message: "the VinDesk display did not register within 25s")
    }

    static func runningKodi() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: kodiBundleIdentifier)
            .first { !$0.isTerminated }
    }

    private func startKodi() async throws {
        guard let kodiURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kodiBundleIdentifier) else {
            throw KodiRPC.Failure(message: "Kodi is not installed")
        }
        setProgress("Starting Kodi…")
        let configuration = NSWorkspace.OpenConfiguration()
        if FileManager.default.isReadableFile(atPath: Self.caBundle.path) {
            let path = Self.caBundle.path
            configuration.environment = ["SSL_CERT_FILE": path, "REQUESTS_CA_BUNDLE": path, "CURL_CA_BUNDLE": path]
        } else {
            logDiagnostic("no CA bundle at \(Self.caBundle.path): Kodi's repository fetches will fail with "
                + "curl error 60, and add-ons using requests with CERTIFICATE_VERIFY_FAILED.")
        }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: kodiURL, configuration: configuration)
        } catch {
            throw KodiRPC.Failure(message: "could not start Kodi: \(error.localizedDescription)")
        }
        // Kodi answers JSON-RPC within a few seconds, well before it is done
        // enumerating displays - `monitorOption` waits out the rest.
        for _ in 0 ..< 30 {
            if await (try? KodiRPC.call("JSONRPC.Ping", timeout: 2)) != nil {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw KodiRPC.Failure(message: "Kodi did not answer JSON-RPC within 60s. Is 'Allow remote control "
            + "from applications on this system' on, in Kodi > Settings > Services > Control?")
    }

    private func stopKodi() async {
        guard let kodi = Self.runningKodi() else {
            return
        }
        kodi.terminate()
        for _ in 0 ..< 40 {
            if kodi.isTerminated {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        logDiagnostic("Kodi did not quit within 20s; forcing it.")
        kodi.forceTerminate()
        try? await Task.sleep(for: .seconds(2))
    }

    /// Asked of Kodi, never computed - see the top of this file. Retried because
    /// Kodi's option list starts out incomplete, before it has enumerated displays.
    private func monitorOption(named name: String) async throws -> String {
        for attempt in 0 ..< 15 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(2))
            }
            let data = try? await KodiRPC.call(
                "Settings.GetSettings",
                ["filter": ["section": "system", "category": "display"]]
            )
            let settings = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["settings"]
            for setting in settings as? [[String: Any]] ?? [] where setting["id"] as? String == Self.monitorSetting {
                for option in setting["options"] as? [[String: Any]] ?? [] {
                    if let value = option["value"] as? String, value.hasPrefix(name) {
                        return value
                    }
                }
            }
        }
        throw KodiRPC.Failure(message: "Kodi does not list a monitor named '\(name)'. It enumerates displays "
            + "only at startup, so launching again may help.")
    }

    private func currentMonitor() async throws -> String {
        let data = try await KodiRPC.call("Settings.GetSettingValue", ["setting": Self.monitorSetting])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["value"] as? String ?? ""
    }

    private func setProgress(_ progress: String?) {
        self.progress = progress
        onChange?()
    }

    // MARK: Session

    /// Records Kodi's display settings before the session changes them. An
    /// existing record means a session is already in progress, and the file
    /// already holds *our* values, so it is kept rather than overwritten.
    private func capturePreSessionSettings() {
        guard !FileManager.default.fileExists(atPath: Self.stateFile.path) else {
            return
        }
        guard let text = try? String(contentsOf: Self.guiSettings, encoding: .utf8) else {
            logDiagnostic("could not read Kodi's display settings; they will not be restored.")
            return
        }
        var lines: [String] = []
        for id in [Self.monitorSetting, Self.screenModeSetting] {
            guard var value = GuiSettings.read(text, id) else {
                continue
            }
            // A previous session that never restored leaves our own display here.
            // Restoring that would strand Kodi on a display that no longer exists.
            if id == Self.monitorSetting, value.hasPrefix(virtualDisplayName) {
                value = "Default"
            }
            lines.append("\(id)=\(value)")
        }
        guard !lines.isEmpty else {
            return
        }
        try? FileManager.default.createDirectory(
            at: Self.stateFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? (lines.joined(separator: "\n") + "\n").write(to: Self.stateFile, atomically: true, encoding: .utf8)
    }

    /// Whether a session's settings are waiting to be put back.
    static var hasSession: Bool {
        FileManager.default.fileExists(atPath: stateFile.path)
    }

    /// Puts Kodi's display settings back. Only once Kodi has exited: it writes
    /// its settings on the way down and would clobber the restore. Only the two
    /// settings the launch changes, so nothing else touched in the session is lost.
    static func finishSession() {
        guard let record = try? String(contentsOf: stateFile, encoding: .utf8) else {
            return
        }
        guard !isKodiRunning else {
            // Not fatal: Kodi falls back to its default display by itself when
            // ours is gone, and the next launch re-converges.
            logDiagnostic("Kodi is still running, so its display settings stay patched.")
            return
        }
        let assignments = record.split(separator: "\n").compactMap { line -> (id: String, value: String)? in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
        if let problem = GuiSettings.apply(assignments, to: guiSettings) {
            logDiagnostic("could not restore Kodi's display settings (\(problem)); the record is kept at \(stateFile.path).")
            return
        }
        try? FileManager.default.removeItem(at: stateFile)
    }
}
