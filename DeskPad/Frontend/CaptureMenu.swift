import Cocoa

/// The Capture menu, shown both from a menu bar icon and in the main menu.
///
/// The items are rebuilt each time a menu opens, so their titles always match
/// the recording state and the allowlist without anything having to keep them
/// in step.
///
/// No key equivalents, deliberately: while the mirror is focused every keystroke
/// is forwarded to the virtual display, and a menu shortcut would silently take
/// its combination away from it.
@MainActor
final class CaptureMenu: NSObject, NSMenuDelegate {
    private let service: CaptureService
    private let window: NSWindow
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(service: CaptureService, window: NSWindow) {
        self.service = service
        self.window = window
        super.init()
        statusItem.menu = makeMenu()
        service.onRecordingChange = { [weak self] in
            self?.updateIcon()
        }
        updateIcon()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Capture")
        menu.delegate = self
        // AppKit draws a status item whose menu has nothing enabled as disabled -
        // dim grey, dark on a dark menu bar - so the menu cannot start out empty
        // and wait to be filled on first open.
        menuNeedsUpdate(menu)
        return menu
    }

    private var recordingTimer: Timer?

    /// While recording, whoever started it, the icon turns into a red record
    /// symbol with the elapsed time: the one reminder that the display is being
    /// recorded, including by another app.
    private func updateIcon() {
        guard let button = statusItem.button else {
            return
        }
        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let session = service.recording else {
            // A template image, so macOS colours it for light and dark menu bars.
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "DeskPad capture")
            button.title = ""
            statusItem.length = NSStatusItem.squareLength
            return
        }
        // Deliberately not a template: a template is recoloured to match the menu
        // bar, which would throw the red away.
        button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "DeskPad is recording")?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        button.imagePosition = .imageLeading
        // Monospaced digits, so the item does not shuffle its neighbours every
        // second as the digits change width.
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.length = NSStatusItem.variableLength

        let showElapsed = { [weak button] in
            let seconds = Int(Date().timeIntervalSince(session.startedAt))
            button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
        }
        showElapsed()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { showElapsed() }
        }
        // Common modes, so it keeps counting while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Take Screenshot", #selector(takeScreenshot)))
        menu.addItem(item(service.recording == nil ? "Start Recording" : "Stop Recording", #selector(toggleRecording)))
        menu.addItem(.separator())
        menu.addItem(item("Open Captures Folder", #selector(openCapturesFolder)))

        let allowed = NSMenu()
        let apps = AllowedApps.all
        if apps.isEmpty {
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            none.isEnabled = false
            allowed.addItem(none)
        }
        for app in apps {
            let entry = item("Remove \(app.name)…", #selector(removeAllowedApp(_:)))
            entry.representedObject = app.requirement
            entry.toolTip = app.requirement
            allowed.addItem(entry)
        }
        let allowedItem = NSMenuItem(title: "Allowed Apps", action: nil, keyEquivalent: "")
        allowedItem.submenu = allowed
        menu.addItem(allowedItem)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Encoding a full-resolution PNG takes a noticeable moment, so it happens
    /// off the main thread.
    @objc private func takeScreenshot() {
        let frames = service.frames
        DispatchQueue.global().async {
            let url = CaptureFolder.newFileURL(extension: "png")
            let error: CaptureError? = switch frames.screenshot(maxWidth: nil, afterT: nil, timeout: 2) {
            case let .success(shot): writeExclusively(shot.png, to: url.path)
            case let .failure(error): error
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        self.showError("The screenshot failed", error)
                    } else {
                        self.confirmScreenshot()
                    }
                }
            }
        }
    }

    /// The same feedback macOS gives for its own screenshots: its shutter sound,
    /// which ships with the system so nothing is bundled, and a white flash over
    /// the mirror. Only after the file is written, so it never signals a
    /// screenshot that did not happen.
    private func confirmScreenshot() {
        NSSound(
            contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            byReference: true
        )?.play()

        guard let layer = window.contentView?.layer else {
            return
        }
        let flash = CALayer()
        flash.frame = layer.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            flash.removeFromSuperlayer()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        fade.duration = 0.4
        flash.add(fade, forKey: nil)
        CATransaction.commit()
    }

    @objc private func toggleRecording() {
        Task {
            if service.recording != nil {
                if case let .failure(error) = await service.stopRecording(by: nil) {
                    showError("Stopping the recording failed", error)
                }
            } else {
                let url = CaptureFolder.newFileURL(extension: "mov")
                if case let .failure(error) = await service.startRecording(
                    to: url,
                    maxWidth: nil,
                    maxSeconds: nil,
                    owner: nil
                ) {
                    showError("The recording could not start", error)
                }
            }
        }
    }

    @objc private func openCapturesFolder() {
        try? FileManager.default.createDirectory(at: CaptureFolder.url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CaptureFolder.url)
    }

    @objc private func removeAllowedApp(_ sender: NSMenuItem) {
        guard let requirement = sender.representedObject as? String else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Stop allowing this app to capture the DeskPad display?"
        alert.informativeText = "It will be asked again the next time it tries.\n\n\(requirement)"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            if response == .alertFirstButtonReturn {
                AllowedApps.remove(requirement: requirement)
            }
        }
    }

    private func showError(_ title: String, _ error: CaptureError) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error.message) (\(error.code))"
        present(alert) { _ in }
    }

    /// Sheets, for the reason `CaptureAPI.prompt` gives: a modal loop inside
    /// main-queue work would stall the mirror.
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        window.deminiaturize(nil)
        NSApp.activate()
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
