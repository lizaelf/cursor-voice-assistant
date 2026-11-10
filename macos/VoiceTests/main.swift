import Foundation

var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        print("ok  \(name)")
    } else {
        failed += 1
        fputs("FAIL \(name)\n", stderr)
    }
}

func response(
    _ phase: Phase,
    method: String = "POST",
    path: String,
    beginSucceeds: Bool = true
) -> (Int, String, Int, Int) {
    var begins = 0
    var finishes = 0
    let result = performRemote(method: method, path: path, phase: phase, begin: {
        begins += 1
        return beginSucceeds
    }, finish: {
        finishes += 1
    })
    return (result.0, result.1, begins, finishes)
}

let startIdle = response(.idle, path: "/start")
check("POST /start з очікування починає один запис", startIdle == (200, #"{"ok":true,"state":"recording"}"#, 1, 0))

let startAgain = response(.recording, path: "/start")
check("повторний POST /start не починає другий запис", startAgain == (200, #"{"ok":true,"state":"recording"}"#, 0, 0))

let startBusy = response(.processing, path: "/start")
check("POST /start під час розпізнавання відхиляється", startBusy == (409, #"{"ok":false,"state":"processing"}"#, 0, 0))

let startNoMic = response(.idle, path: "/start", beginSucceeds: false)
check("POST /start без мікрофона не вдає запис", startNoMic == (409, #"{"ok":false,"state":"idle"}"#, 1, 0))

let stopRecording = response(.recording, path: "/stop")
check("POST /stop під час запису розпізнає один раз", stopRecording == (200, #"{"ok":true,"state":"processing"}"#, 0, 1))

let stopBusy = response(.processing, path: "/stop")
check("POST /stop під час розпізнавання не зупиняє вдруге", stopBusy == (200, #"{"ok":true,"state":"processing"}"#, 0, 0))

let stopIdle = response(.idle, path: "/stop")
check("POST /stop без запису відповідає і нічого не чіпає", stopIdle == (200, #"{"ok":true,"state":"idle"}"#, 0, 0))

let getStart = response(.idle, method: "GET", path: "/start")
check("GET /start не починає запис", getStart.0 == 404 && getStart.2 == 0 && getStart.3 == 0)

let unknown = response(.recording, path: "/pause")
check("невідомий шлях нічого не змінює", unknown == (404, #"{"ok":false}"#, 0, 0))

let request = Data("POST /start HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n".utf8)
check("з запиту читається метод і шлях", parseHTTPRequestLine(request) == HTTPRequestLine(method: "POST", path: "/start"))

let query = Data("POST /start?x=1 HTTP/1.1\r\n\r\n".utf8)
check("шлях із параметрами не збігається зі /start", remoteAction(method: parseHTTPRequestLine(query).method, path: parseHTTPRequestLine(query).path) == .reject)

let idleBody = #"{"ok":true,"state":"idle"}"#
let message = String(data: httpMessage(code: 200, body: idleBody), encoding: .utf8) ?? ""
check(
    "відповідь закриває з’єднання і має довжину тіла",
    message.hasPrefix("HTTP/1.1 200 OK\r\n")
        && message.contains("Content-Length: \(idleBody.utf8.count)\r\n")
        && message.contains("Connection: close\r\n\r\n\(idleBody)")
)
check("відповідь 409 має статус Conflict", String(data: httpMessage(code: 409, body: #"{"ok":false}"#), encoding: .utf8)?.hasPrefix("HTTP/1.1 409 Conflict\r\n") == true)
check("відповідь 404 має статус Not Found", String(data: httpMessage(code: 404, body: #"{"ok":false}"#), encoding: .utf8)?.hasPrefix("HTTP/1.1 404 Not Found\r\n") == true)

check("віджет схований у спокої", showsWidget(voiceIdleStatus) == false)
check("віджет видно під час слухання і розпізнавання", showsWidget("Слухаю") && showsWidget("Розпізнаю…") && showsWidget("Вставляю…"))

check("запис коротший за 0,4 с не розпізнається", shouldTranscribe(duration: 0) == false && shouldTranscribe(duration: 0.39) == false)
check("запис від 0,4 с розпізнається", shouldTranscribe(duration: 0.4) && shouldTranscribe(duration: 3.2))

check("Command+D перехоплюється", swallowsHotkey(KeyPress(keyCode: 0x02, command: true, keyDown: true, repeated: false)))
check("повтор Command+D не перехоплюється", swallowsHotkey(KeyPress(keyCode: 0x02, command: true, keyDown: true, repeated: true)) == false)
check("D без Command не перехоплюється", swallowsHotkey(KeyPress(keyCode: 0x02, command: false, keyDown: true, repeated: false)) == false)
check("Command+I і Command+V не перехоплюються", swallowsHotkey(KeyPress(keyCode: 0x22, command: true, keyDown: true, repeated: false)) == false && swallowsHotkey(KeyPress(keyCode: 0x09, command: true, keyDown: true, repeated: false)) == false)
check("відпускання D не перехоплюється", swallowsHotkey(KeyPress(keyCode: 0x02, command: true, keyDown: false, repeated: false)) == false)

let paste = cursorPastePlan()
check(
    "вставка фокусує чат, вставляє з буфера і відправляє Enter",
    paste == [
        PasteKey(keyCode: 0x22, command: true),
        PasteKey(keyCode: 0x09, command: true),
        PasteKey(keyCode: 0x24, command: false),
    ]
)
check("відправлення не тримає Command", paste.last?.command == false)

let arguments = whisperArguments(model: "models/ggml-small.bin", audio: "recordings/a.wav")
check("розпізнавання примусово українською", arguments.contains("-l") && arguments[arguments.firstIndex(of: "-l")! + 1] == "uk")
check("prompt українською і без англійського списку слів", arguments[arguments.firstIndex(of: "--prompt")! + 1] == "Українською мовою.")
check("prompt не передається прапорцем -p", arguments.contains("-p") == false)

let raw = """
[00:00.000 --> 00:01.200]  Кажу якесь речення
[BLANK_AUDIO]
[00:01.200 --> 00:02.000]   ще раз
"""
check("з відповіді whisper зникають мітки часу", cleanTranscript(raw) == "Кажу якесь речення ще раз")
check("порожня відповідь лишається порожньою", cleanTranscript("\n[BLANK_AUDIO]\n") == "")

check("сервер слухає порт 8765", voiceListenPort == 8765)

if failed > 0 {
    fputs("\nНе пройшло: \(failed)\n", stderr)
    exit(1)
}
print("\nУсі перевірки пройшли")
