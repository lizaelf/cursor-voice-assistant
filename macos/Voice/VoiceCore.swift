import Foundation

let voiceHotkeyKeyCode: Int64 = 0x02
let voiceMinimumDuration = 0.4
let voiceListenPort: UInt16 = 8765
let voiceInitialPrompt = "Українською мовою."
let voiceIdleStatus = "⌘D"

enum Phase {
    case idle
    case recording
    case processing
}

enum RemoteAction {
    case start
    case stop
    case reject
}

struct HTTPRequestLine: Equatable {
    var method: String
    var path: String
}

struct KeyPress {
    var keyCode: Int64
    var command: Bool
    var keyDown: Bool
    var repeated: Bool
}

struct PasteKey: Equatable {
    var keyCode: UInt16
    var command: Bool
}

func remoteAction(method: String, path: String) -> RemoteAction {
    if method == "POST", path == "/start" {
        return .start
    }
    if method == "POST", path == "/stop" {
        return .stop
    }
    return .reject
}

func parseHTTPRequestLine(_ data: Data) -> HTTPRequestLine {
    let text = String(data: data, encoding: .utf8) ?? ""
    let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let parts = requestLine.split(separator: " ")
    return HTTPRequestLine(
        method: parts.first.map(String.init) ?? "",
        path: parts.dropFirst().first.map(String.init) ?? ""
    )
}

func performRemote(
    method: String,
    path: String,
    phase: Phase,
    begin: () -> Bool,
    finish: () -> Void
) -> (Int, String) {
    switch remoteAction(method: method, path: path) {
    case .start:
        switch phase {
        case .recording:
            return (200, #"{"ok":true,"state":"recording"}"#)
        case .processing:
            return (409, #"{"ok":false,"state":"processing"}"#)
        case .idle:
            if begin() {
                return (200, #"{"ok":true,"state":"recording"}"#)
            }
            return (409, #"{"ok":false,"state":"idle"}"#)
        }
    case .stop:
        switch phase {
        case .recording:
            finish()
            return (200, #"{"ok":true,"state":"processing"}"#)
        case .processing:
            return (200, #"{"ok":true,"state":"processing"}"#)
        case .idle:
            return (200, #"{"ok":true,"state":"idle"}"#)
        }
    case .reject:
        return (404, #"{"ok":false}"#)
    }
}

func httpMessage(code: Int, body: String) -> Data {
    let reason: String
    switch code {
    case 200: reason = "OK"
    case 404: reason = "Not Found"
    case 409: reason = "Conflict"
    default: reason = "Error"
    }
    let payload = Data(body.utf8)
    let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    var bytes = Data(header.utf8)
    bytes.append(payload)
    return bytes
}

func showsWidget(_ status: String) -> Bool {
    status != voiceIdleStatus
}

func shouldTranscribe(duration: Double) -> Bool {
    duration >= voiceMinimumDuration
}

func swallowsHotkey(_ press: KeyPress) -> Bool {
    press.keyDown && press.keyCode == voiceHotkeyKeyCode && press.command && !press.repeated
}

func cursorPastePlan() -> [PasteKey] {
    [
        PasteKey(keyCode: 0x22, command: true),
        PasteKey(keyCode: 0x09, command: true),
    ]
}

func whisperArguments(model: String, audio: String) -> [String] {
    [
        "-m", model,
        "-f", audio,
        "-l", "uk",
        "-nt",
        "-np",
        "--prompt", voiceInitialPrompt,
    ]
}

func cleanTranscript(_ stdout: String) -> String {
    let timestamp = try? NSRegularExpression(pattern: #"^\[\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}\.\d{3}\]\s*"#)
    var lines: [String] = []
    for raw in stdout.split(whereSeparator: \.isNewline) {
        var line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if let timestamp, let match = timestamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           match.range.location == 0, let range = Range(match.range, in: line) {
            line = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if line.isEmpty { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") { continue }
        lines.append(line)
    }
    return lines.joined(separator: " ")
}
