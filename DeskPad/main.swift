import AppKit

/// `NSApplication.delegate` is a *weak* reference, and with no MainMenu.xib and
/// no `NSPrincipalClass` there is nothing else to own the delegate - so it is
/// held here, where a top-level `let` in main.swift is a process-lifetime global.
///
/// This file looks redundant next to `NSApplicationMain` and is not. Replacing it
/// with `@main` on AppDelegate leaves NSApplicationMain with nothing to
/// instantiate: the app launches, `applicationDidFinishLaunching` never runs, and
/// no window or virtual display is ever created. Verified by doing exactly that.
///
/// `assumeIsolated` because top-level code is not main-actor isolated in the
/// Swift 5 language mode, while AppDelegate and everything it owns are. This runs
/// on the main thread before the run loop starts, so the assumption holds.
let delegate = MainActor.assumeIsolated { () -> AppDelegate in
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    return delegate
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
