import Cocoa
import Network

let kodiBundleIdentifier = "org.xbmc.kodi"

func isKodi(_ pid: pid_t) -> Bool {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == kodiBundleIdentifier
}

/// Kodi, if it is the app showing on the given display.
func kodi(on displayID: CGDirectDisplayID) -> NSRunningApplication? {
    guard
        let pid = topmostWindowOwner(where: { $0.intersects(CGDisplayBounds(displayID)) }),
        isKodi(pid)
    else {
        return nil
    }
    return NSRunningApplication(processIdentifier: pid)
}

/// Fire-and-forget JSON-RPC client for Kodi's raw TCP transport.
///
/// Why Kodi gets its own channel rather than synthetic key events: Kodi reads the
/// keyboard off the AppKit responder chain (`-[OSXGLView keyDown:]` forwards to
/// `CWinEventsOSXImpl`), and responder delivery needs a key window, which an
/// inactive app does not have. Since the whole point here is to type while
/// DeskPad - not Kodi - holds focus, an injected key event has nowhere to land.
/// JSON-RPC sidesteps focus entirely; verified driving a background Kodi.
/// `@unchecked` rather than an actor, deliberately. Every mutable member below
/// is touched only on `queue` - including `stateUpdateHandler` and the send
/// completion, because the connection is started with `start(queue: queue)` - so
/// the isolation is real, just invisible to the compiler.
///
/// An actor would express that in the type system but break the ordering this
/// depends on: `Task { await remote.pressKey(...) }` has no FIFO guarantee
/// between tasks, so at key-repeat rates keystrokes could reach Kodi out of
/// order. A serial DispatchQueue does guarantee it.
final class KodiRemote: @unchecked Sendable {
    static let shared = KodiRemote()

    private let queue = DispatchQueue(label: "com.jellyvin.deskpad.kodi-rpc")
    private var connection: NWConnection?
    /// Set once a send or the connection fails, so a Kodi that is not listening
    /// costs one log line rather than one per keystroke at key-repeat rate.
    private var hasLoggedFailure = false

    /// Presses a keyboard button by Kodi's own name for it ("left", "escape", "i").
    ///
    /// `Input.ButtonEvent` with keymap `KB` hands Kodi a keyboard button and lets
    /// Kodi's keymap decide what it means, so the mirror inherits whatever that
    /// key already does in Kodi - including the user's own keymap edits. Mapping
    /// keys to semantic actions (`Input.Select`, `Input.Back`) instead would
    /// hard-code one interpretation and get the context-dependent ones wrong.
    func pressKey(named button: String) {
        send(method: "Input.ButtonEvent", params: ["button": button, "keymap": "KB"])
    }

    /// Asks Kodi to quit. `delivered` reports whether the request reached the
    /// socket, so a caller waiting on Kodi to exit can give up immediately rather
    /// than sitting out a timeout when Kodi was never listening.
    func requestQuit(delivered: @escaping @Sendable (Bool) -> Void) {
        send(method: "Application.Quit", params: [:], delivered: delivered)
    }

    /// Sent as a JSON-RPC *notification* - no `id`, so Kodi sends no reply and we
    /// never read. At key-repeat rates, waiting for a response per keystroke would
    /// serialise typing behind Kodi's answer.
    private func send(method: String, params: [String: Any], delivered: (@Sendable (Bool) -> Void)? = nil) {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            delivered?(false)
            return
        }
        queue.async {
            self.activeConnection().send(content: data, completion: .contentProcessed { error in
                guard let error else {
                    delivered?(true)
                    return
                }
                delivered?(false)
                self.queue.async {
                    self.report("send failed: \(error)")
                    self.reset()
                }
            })
        }
    }

    /// One long-lived connection: Kodi's TCP transport is a persistent stream, and
    /// reconnecting per keystroke would add a handshake to every one.
    private func activeConnection() -> NWConnection {
        if let connection {
            return connection
        }
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: 9090),
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            switch state {
            case .ready:
                hasLoggedFailure = false

            // `.waiting` is a refused connection that NWConnection intends to
            // retry. Left alone it would silently swallow every keystroke, so
            // treat it as terminal and reconnect on the next one instead.
            case let .waiting(error):
                report("cannot reach Kodi: \(error)")
                reset()

            case let .failed(error):
                report("connection failed: \(error)")
                reset()

            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        return connection
    }

    private func reset() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func report(_ message: String) {
        guard !hasLoggedFailure else {
            return
        }
        hasLoggedFailure = true
        logDiagnostic("Kodi JSON-RPC (127.0.0.1:9090) \(message). Keys typed at the "
            + "mirror will not reach Kodi. Enable Kodi > Settings > Services > "
            + "Control > 'Allow remote control from applications on this system'.")
    }
}
