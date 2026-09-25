import ApplicationServices
import Cocoa

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    /// The single owner of the app's state. Handed to whoever needs it rather
    /// than reached for globally.
    private let model = AppModel()

    private var captureService: CaptureService?
    private var captureMenu: CaptureMenu?
    private var captureAPI: CaptureAPI?

    func applicationDidFinishLaunching(_: Notification) {
        // Before the view controller, which creates the virtual display: the
        // model has to be watching for screen parameter changes already, or the
        // notification announcing the new display is missed.
        model.start()

        let viewController = ScreenViewController(model: model)
        let window = NSWindow(contentViewController: viewController)
        window.delegate = viewController
        window.title = "DeskPad"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 5120, height: 2160)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)

        window.setContentSize(CGSize(width: 1187, height: 668))
        window.center()
        // setFrameAutosaveName only registers the name; setFrameUsingName reports
        // whether a previously saved frame actually existed to restore.
        window.setFrameAutosaveName("MainWindow")
        window.setFrameUsingName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        self.window = window

        let mainMenu = NSMenu()
        let mainMenuItem = NSMenuItem()
        let subMenu = NSMenu(title: "MainMenu")
        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        subMenu.addItem(quitMenuItem)
        mainMenuItem.submenu = subMenu

        let captureService = CaptureService(model: model)
        captureService.start()
        let captureMenu = CaptureMenu(service: captureService, window: window)
        let captureMenuItem = NSMenuItem()
        captureMenuItem.submenu = captureMenu.makeMenu()
        mainMenu.items = [mainMenuItem, captureMenuItem]
        NSApplication.shared.mainMenu = mainMenu

        let captureAPI = CaptureAPI(service: captureService, window: window)
        captureAPI.start()
        self.captureService = captureService
        self.captureMenu = captureMenu
        self.captureAPI = captureAPI

        requestEventPostingAccessIfNeeded()
    }

    /// Clicking the mirrored screen forwards a synthetic mouse event, and macOS
    /// gates event *injection* behind its own TCC service (`kTCCServicePostEvent`),
    /// which is distinct from Accessibility - granting Accessibility alone leaves
    /// `CGEvent.post` silently failing, so the cursor warps but no click ever
    /// arrives. `CGRequestPostEventAccess` is the API that asks for the right one.
    private func requestEventPostingAccessIfNeeded() {
        guard !CGPreflightPostEventAccess() else {
            return
        }
        let granted = CGRequestPostEventAccess()
        logDiagnostic("no event-posting access; requested it -> granted=\(granted). "
            + "Until granted, clicks on the mirror move the cursor but do not click.")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Takes Kodi down with us, and - the whole point - does it *before* the
    /// virtual display goes away.
    ///
    /// Order is everything here. The virtual display exists only as long as this
    /// process does, so a Kodi still running when DeskPad exits is instantly
    /// homeless: macOS moves it to the built-in display, where it reappears
    /// fullscreen across the user's actual screen until it finally quits. Quitting
    /// Kodi first and holding termination open until it is gone means it never has
    /// a chance to migrate.
    ///
    /// `.terminateLater` rather than blocking in `applicationWillTerminate`: the
    /// run loop keeps turning, so the mirror carries on rendering and the window
    /// does not beachball while Kodi shuts down.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // A movie is only playable once its recording is finalised, so quitting
        // mid-recording would leave a broken file. Finish it, then quit again.
        if let captureService, captureService.recording != nil {
            Task {
                _ = await captureService.stopRecording(by: nil)
                // Not straight from this task. `terminate` spins a nested event
                // loop until the Kodi shutdown below replies, and that reply
                // arrives as main-queue work - which cannot run while this task,
                // itself main-queue work, is still on the queue. Calling it here
                // deadlocked quitting outright. A run loop block is not
                // main-queue work, so the reply gets through.
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        NSApp.terminate(nil)
                    }
                }
            }
            return .terminateCancel
        }

        guard
            let displayID = model.displayID,
            let kodi = kodi(on: displayID)
        else {
            return .terminateNow
        }

        // Whatever happens below, terminating must not be able to hang. Every
        // path ends at replyToTerminate(), which only ever fires once, and this
        // backstop covers the ones that never report back at all - a connection
        // that stays stuck in setup has no completion and no exit to observe.
        DispatchQueue.main.asyncAfter(deadline: .now() + kodiQuitTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasRepliedToTerminate else {
                    return
                }
                logDiagnostic("Kodi was asked to quit but had not exited after "
                    + "\(Int(self.kodiQuitTimeout))s; quitting anyway. It may reappear on the "
                    + "built-in display until it finishes shutting down.")
                self.replyToTerminate()
            }
        }

        KodiRemote.shared.requestQuit { [weak self] delivered in
            // The reply lands on KodiRemote's own queue; everything it leads to
            // is main-actor state, so hop before touching any of it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    guard delivered else {
                        // Kodi was not listening, so there is nothing to wait
                        // for. The launcher's watcher still cleans up after the
                        // display goes.
                        self.replyToTerminate()
                        return
                    }
                    self.waitForExit(of: kodi)
                }
            }
        }
        return .terminateLater
    }

    private let kodiQuitTimeout: TimeInterval = 8

    private var kodiTerminationObserver: (any NSObjectProtocol)?

    /// Replies once Kodi has actually exited.
    ///
    /// Driven by the notification macOS already publishes, rather than the
    /// `usleep` loop this replaced - that parked an entire thread for up to the
    /// full timeout to watch a flag that AppKit will simply tell us about.
    private func waitForExit(of kodi: NSRunningApplication) {
        kodiTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard terminated?.processIdentifier == kodi.processIdentifier else {
                return
            }
            MainActor.assumeIsolated {
                self?.replyToTerminate()
            }
        }

        // Registered first, then checked: the other order leaves a window where
        // Kodi exits in between and the notification is never seen. Replying
        // twice is harmless - replyToTerminate only fires once.
        if kodi.isTerminated {
            replyToTerminate()
        }
    }

    private var hasRepliedToTerminate = false

    private func replyToTerminate() {
        DispatchQueue.main.async { [self] in
            guard !hasRepliedToTerminate else {
                return
            }
            hasRepliedToTerminate = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}
