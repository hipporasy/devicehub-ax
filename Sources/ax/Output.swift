import Foundation

/// Exit codes are part of the interface: scripts and agents branch on them.
enum ExitCode: Int32 {
    case success = 0
    case notFound = 1
    case usage = 2
    case accessibilityDenied = 3
    case deviceHubUnavailable = 4
    case actionFailed = 5
    case simulatorToolFailed = 6
}

struct Failure: Error {
    let code: ExitCode
    let kind: String
    let message: String
    var hint: String?
    var details: [String: Any] = [:]

    init(_ code: ExitCode, _ kind: String, _ message: String, hint: String? = nil, details: [String: Any] = [:]) {
        self.code = code
        self.kind = kind
        self.message = message
        self.hint = hint
        self.details = details
    }
}

var jsonOutput = false

func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
}

/// Prints one JSON object with `"ok": true` in --json mode, or the text otherwise.
func emit(_ object: [String: Any], text: @autoclosure () -> String) {
    if jsonOutput {
        var payload = object
        payload["ok"] = true
        print(jsonString(payload))
    } else {
        let lines = text()
        if !lines.isEmpty { print(lines) }
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("warning: " + message + "\n").utf8))
}

func finish(with failure: Failure) -> Never {
    if jsonOutput {
        var payload = failure.details
        payload["ok"] = false
        payload["error"] = failure.kind
        payload["message"] = failure.message
        if let hint = failure.hint { payload["hint"] = hint }
        print(jsonString(payload))
    }
    var text = failure.message
    if let hint = failure.hint { text += "\nhint: " + hint }
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(failure.code.rawValue)
}

/// Calls `body` every quarter second until it returns a value or `timeout` seconds pass.
func poll<T>(timeout: Double, _ body: () throws -> T?) rethrows -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if let value = try body() { return value }
        if Date() >= deadline { return nil }
        Thread.sleep(forTimeInterval: 0.25)
    }
}
