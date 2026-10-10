import Foundation

/// Appends to ~/Library/Logs/vindesk.log.
///
/// Reserved for the failures whose only other symptom is silence - a missing TCC
/// grant, or a Kodi that is not listening for remote control - because what the
/// user sees in both cases is just "input mysteriously does nothing". The file
/// staying absent means input forwarding is healthy. A plain file rather than
/// NSLog: NSLog does not reliably surface in `log show` for this process.
func logDiagnostic(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/vindesk.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
