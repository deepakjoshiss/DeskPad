import ApplicationServices
import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_: Notification) {
        let viewController = ScreenViewController()
        window = NSWindow(contentViewController: viewController)
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

        window.setContentSize(CGSize(width: 960, height: 540))
        window.center()
        // setFrameAutosaveName only registers the name; setFrameUsingName reports
        // whether a previously saved frame actually existed to restore.
        window.setFrameAutosaveName("MainWindow")
        window.setFrameUsingName("MainWindow")
        window.makeKeyAndOrderFront(nil)

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
        mainMenu.items = [mainMenuItem]
        NSApplication.shared.mainMenu = mainMenu

        requestEventPostingAccessIfNeeded()

        store.dispatch(AppDelegateAction.didFinishLaunching)
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
        return true
    }
}
