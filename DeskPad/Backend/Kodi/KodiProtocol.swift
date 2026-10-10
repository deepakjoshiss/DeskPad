import Foundation

/// Edits Kodi's guisettings.xml. Only ever while Kodi is stopped: Kodi holds
/// settings in memory and writes them out on change and on exit, so it happily
/// clobbers edits made underneath it.
///
/// Two details matter, both learned the hard way:
///
///   * A setting carrying `default="true"` is treated by Kodi as "use the
///     built-in default" and its stored text is ignored. The attribute must go,
///     or the edit silently does nothing.
///   * Settings appear as `<setting id="x">v</setting>`, or self-closing when
///     empty, so both forms are handled.
///
/// Only the matched element is rewritten, rather than re-serialising the
/// document, so a file Kodi owns is not reformatted.
enum GuiSettings {
    /// The setting's current value, or nil if it is not in the file.
    static func read(_ text: String, _ id: String) -> String? {
        guard let match = match(text, id) else {
            return nil
        }
        return unescape(group(match, "value", in: text) ?? "")
    }

    /// The text with the setting set, or nil if the setting is not in the file.
    static func patched(_ text: String, _ id: String, to value: String) -> String? {
        guard let match = match(text, id) else {
            return nil
        }
        let hadDefault = group(match, "attrs", in: text)?.contains(#"default="true""#) ?? false
        if group(match, "value", in: text) == escape(value), !hadDefault {
            return text
        }
        let indent = group(match, "indent", in: text) ?? ""
        let replacement = "\(indent)<setting id=\"\(id)\">\(escape(value))</setting>"
        return (text as NSString).replacingCharacters(in: match.range, with: replacement)
    }

    /// Applies every assignment, writing the file only if something changed and
    /// then atomically, so a crash cannot leave Kodi a truncated settings file.
    /// Reports what could not be done; nil means all of it was.
    static func apply(_ assignments: [(id: String, value: String)], to url: URL) -> String? {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            return "cannot read \(url.path)"
        }
        let original = text
        var missing: [String] = []
        for (id, value) in assignments {
            if let patched = patched(text, id, to: value) {
                text = patched
            } else {
                missing.append(id)
            }
        }
        if text != original {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "cannot write \(url.path): \(error.localizedDescription)"
            }
        }
        return missing.isEmpty ? nil : "not in \(url.lastPathComponent): \(missing.joined(separator: ", "))"
    }

    private static func match(_ text: String, _ id: String) -> NSTextCheckingResult? {
        let pattern = #"(?<indent>[ \t]*)<setting\s+id=""#
            + NSRegularExpression.escapedPattern(for: id)
            + #""(?<attrs>[^>]*?)(?:/>|>(?<value>.*?)</setting>)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
        return regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ name: String, in text: String) -> String? {
        Range(match.range(withName: name), in: text).map { String(text[$0]) }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Request-and-reply JSON-RPC over Kodi's raw TCP transport (127.0.0.1:9090).
///
/// `KodiRemote` covers the fire-and-forget side - keystrokes - on a long-lived
/// connection. This is for questions that need an answer, one connection each.
enum KodiRPC {
    struct Failure: Error {
        let message: String
    }

    private static let requestID = "vindesk-launcher"

    /// The call's `result`, as JSON. Blocks, so it runs off the main thread.
    static func call(_ method: String, _ params: [String: Any]? = nil, timeout: Int = 6) async throws -> Data {
        var request: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method]
        if let params {
            request["params"] = params
        }
        let payload = try JSONSerialization.data(withJSONObject: request)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try exchange(payload, timeout: timeout) })
            }
        }
    }

    private static func exchange(_ payload: Data, timeout: Int) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw Failure(message: "socket() failed")
        }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9090).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw Failure(message: "Kodi is not listening on 127.0.0.1:9090")
        }
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == payload.count else {
            throw Failure(message: "could not send the request to Kodi")
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                throw Failure(message: count == 0 ? "Kodi closed the connection" : "no reply from Kodi")
            }
            buffer.append(contentsOf: chunk[0 ..< count])
            // Kodi may push notifications ahead of the reply asked for.
            while let (object, rest) = splitFirstObject(buffer) {
                buffer = rest
                guard
                    let message = try? JSONSerialization.jsonObject(with: object) as? [String: Any],
                    message["id"] as? String == requestID
                else {
                    continue
                }
                if let error = message["error"] {
                    throw Failure(message: "Kodi returned an error: \(error)")
                }
                return try JSONSerialization.data(withJSONObject: message["result"] ?? NSNull(), options: .fragmentsAllowed)
            }
        }
    }

    /// Kodi's TCP transport has no framing - objects simply follow one another
    /// on a stream that never closes - so complete objects are found by
    /// balancing braces outside strings. nil until one has fully arrived.
    static func splitFirstObject(_ data: Data) -> (Data, Data)? {
        var depth = 0
        var inString = false
        var escaped = false
        var start: Int?
        for (index, byte) in data.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                if depth == 0 {
                    start = index
                }
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0, let start {
                    let base = data.startIndex
                    return (data[base + start ... base + index], data[(base + index + 1)...])
                }
            default:
                break
            }
        }
        return nil
    }
}
