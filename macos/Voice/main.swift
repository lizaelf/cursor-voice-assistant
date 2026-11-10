import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Darwin
import Network

private let cursorBundleID = "com.todesktop.230313mzl4w4u92"

private func repoRoot() -> URL {
    let besideApp = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let known = URL(fileURLWithPath: "/Users/mac/Documents/git/cursor-voice-assistant")
    for candidate in [besideApp, known] {
        let model = candidate.appendingPathComponent("models/ggml-small.bin")
        if FileManager.default.fileExists(atPath: model.path) {
            return candidate
        }
    }
    return known
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let controller = Unmanaged<AppController>.fromOpaque(userInfo!).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = controller.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let press = KeyPress(
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        command: event.flags.contains(.maskCommand),
        keyDown: type == .keyDown,
        repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    )
    guard swallowsHotkey(press) else {
        return Unmanaged.passUnretained(event)
    }

    DispatchQueue.main.async {
        controller.handleHotkey()
    }
    return nil
}

final class AppController: NSObject, NSApplicationDelegate {
    let root = repoRoot()
    var eventTap: CFMachPort?
    var phase: Phase = .idle
    var recorder: AVAudioRecorder?
    var recordingURL: URL?

    var panel: NSPanel!
    var pillLabel: NSTextField!
    var waveBars: [NSView] = []
    var waveTimer: Timer?
    var statusItem: NSStatusItem?
    var addressItem: NSMenuItem?
        var httpServer: VoiceHTTPServer?
    let wifiSetup = WifiSetupController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWidget()
        installStatusItem()
        requestMicrophone()
        installHotkeyIfTrusted()
        let server = VoiceHTTPServer(controller: self)
        httpServer = server
        server.start()
        if !wifiSetup.hasSavedPassword() {
            wifiSetup.show(nil)
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.installHotkeyIfTrusted()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
    }

    func handleHotkey() {
        switch phase {
        case .recording:
            finishRecording()
        case .processing:
            setStatus("Ще розпізнаю попередній запис.")
        case .idle:
            beginRecording()
        }
    }

    func startFromRemote() -> (Int, String) {
        performRemote(method: "POST", path: "/start", phase: phase, begin: {
            self.beginRecording()
            return self.phase == .recording
        }, finish: {})
    }

    func stopFromRemote() -> (Int, String) {
        performRemote(method: "POST", path: "/stop", phase: phase, begin: { false }, finish: {
            self.finishRecording()
        })
    }

    func publishAddress(_ url: String) {
        addressItem?.title = url
        print("Voice слухає ESP32: \(url)")
        print("POST /start")
        print("POST /stop")
        fflush(stdout)
    }

    private func buildWidget() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 148, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .readOnly
        panel.isMovableByWindowBackground = true

        let content = PillBackground(frame: NSRect(x: 0, y: 0, width: 148, height: 48))
        content.autoresizingMask = [.width, .height]
        panel.contentView = content

        for index in 0..<5 {
            let bar = NSView(frame: NSRect(x: 16 + CGFloat(index) * 5, y: 18, width: 3, height: 12))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = NSColor.white.cgColor
            bar.layer?.cornerRadius = 1.5
            bar.isHidden = true
            content.addSubview(bar)
            waveBars.append(bar)
        }

        pillLabel = NSTextField(labelWithString: voiceIdleStatus)
        pillLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        pillLabel.textColor = .white
        pillLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(pillLabel)
        setStatus(voiceIdleStatus)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "V"
        let menu = NSMenu()
        let address = NSMenuItem(title: "Шукаю адресу…", action: nil, keyEquivalent: "")
        address.isEnabled = false
        menu.addItem(address)
        addressItem = address
        let wifi = NSMenuItem(
            title: "Wi-Fi для плати…",
            action: #selector(WifiSetupController.show(_:)),
            keyEquivalent: ""
        )
        wifi.target = wifiSetup
        menu.addItem(wifi)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Закрити Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
    }

    private func installHotkeyIfTrusted() {
        if eventTap != nil {
            return
        }
        guard AXIsProcessTrusted() else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyCallback,
            userInfo: pointer
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func beginRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            requestMicrophone()
            if AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined {
                setStatus("Дозволь мікрофон для Voice у Захист і безпека → Конфіденційність → Мікрофон.")
                hideWhenIdle()
            }
            return
        }
        activateCursor()

        let folder = root.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let audio = try AVAudioRecorder(url: url, settings: settings)
            audio.prepareToRecord()
            guard audio.record() else {
                setStatus("Не вдалося почати запис із мікрофона.")
                hideWhenIdle()
                return
            }
            recorder = audio
            recordingURL = url
            phase = .recording
            showListening()
        } catch {
            setStatus("Не вдалося почати запис: \(error.localizedDescription)")
            hideWhenIdle()
        }
    }

    private func finishRecording() {
        let duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        let url = recordingURL
        recordingURL = nil
        phase = .processing

        guard let url, shouldTranscribe(duration: duration) else {
            phase = .idle
            setStatus("Занадто коротко")
            hideWhenIdle()
            return
        }

        setStatus("Розпізнаю…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.transcribe(url: url)
            DispatchQueue.main.async {
                self.phase = .idle
                switch result {
                case .success(let text) where text.isEmpty:
                    self.setStatus("Нічого не розпізнано")
                    self.hideWhenIdle()
                case .success(let text):
                    self.save(text)
                    self.copyToPasteboard(text)
                    self.insertIntoCursor()
                case .failure(let error):
                    self.setStatus(error.localizedDescription)
                    self.hideWhenIdle()
                }
            }
        }
    }

    private func transcribe(url: URL) -> Result<String, Error> {
        let whisper = root.appendingPathComponent("third_party/whisper.cpp/build/bin/whisper-cli")
        let model = root.appendingPathComponent("models/ggml-small.bin")
        guard FileManager.default.fileExists(atPath: whisper.path) else {
            return .failure(TranscribeError("Не знайдено whisper-cli."))
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            return .failure(TranscribeError("Не знайдено модель models/ggml-small.bin."))
        }

        let process = Process()
        process.executableURL = whisper
        process.arguments = whisperArguments(model: model.path, audio: url.path)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error)
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let details = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(TranscribeError("whisper-cli завершився з помилкою. \(details)"))
        }
        return .success(cleanTranscript(output))
    }

    private func save(_ text: String) {
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("last_transcript.txt")
        try? (text + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func insertIntoCursor() {
        setStatus("Вставляю…")
        whenCursorIsFront { [weak self] in
            self?.postPaste(cursorPastePlan(), index: 0)
        }
    }

    private func postPaste(_ steps: [PasteKey], index: Int) {
        guard index < steps.count else {
            setStatus("У чаті")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.phase == .idle else { return }
                self.setStatus(voiceIdleStatus)
            }
            return
        }
        let step = steps[index]
        postKey(CGKeyCode(step.keyCode), command: step.command)
        let delay = index == 0 ? 0.55 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.postPaste(steps, index: index + 1)
        }
    }

    private func whenCursorIsFront(attempt: Int = 0, then: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == cursorBundleID {
            then()
            return
        }
        if attempt == 0 {
            activateCursor()
        }
        if attempt >= 40 {
            setStatus("Cursor не відкрився")
            hideWhenIdle()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.whenCursorIsFront(attempt: attempt + 1, then: then)
        }
    }

    private func postKey(_ keyCode: CGKeyCode, command: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        if command {
            down?.flags = .maskCommand
            up?.flags = .maskCommand
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func activateCursor() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cursorBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            return
        }
        let fallback = URL(fileURLWithPath: "/Applications/Cursor.app")
        guard FileManager.default.fileExists(atPath: fallback.path) else { return }
        NSWorkspace.shared.openApplication(at: fallback, configuration: configuration, completionHandler: nil)
    }

    private func showListening() {
        setStatus("Слухаю")
        panel.orderFrontRegardless()
    }

    private func setStatus(_ text: String) {
        guard pillLabel != nil else { return }
        pillLabel.stringValue = text
        let listening = text == "Слухаю"
        waveBars.forEach { $0.isHidden = !listening }
        if listening {
            startWave()
        } else {
            stopWave()
        }

        let font = pillLabel.font ?? NSFont.systemFont(ofSize: 15, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let height: CGFloat = 48
        let width = min(420, max(listening ? 188 : 112, ceil(textWidth) + (listening ? 78 : 40)))
        pillLabel.frame = NSRect(
            x: listening ? 48 : 16,
            y: (height - 22) / 2,
            width: width - (listening ? 64 : 32),
            height: 22
        )
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.minY + 18, width: width, height: height),
            display: showsWidget(text)
        )
        panel.contentView?.needsDisplay = true
        if !showsWidget(text) {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func hideWhenIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.setStatus(voiceIdleStatus)
        }
    }

    private func startWave() {
        if waveTimer != nil { return }
        waveTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.tickWave()
        }
    }

    private func stopWave() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    private func tickWave() {
        let time = Date().timeIntervalSinceReferenceDate
        for (index, bar) in waveBars.enumerated() {
            let height = 7 + 12 * (0.5 + 0.5 * sin(time * 7 + Double(index) * 0.85))
            bar.frame = NSRect(x: 16 + CGFloat(index) * 5, y: (48 - height) / 2, width: 3, height: height)
        }
    }
}

final class PillBackground: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 0.08, alpha: 0.96).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private struct TranscribeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func localIPv4() -> String {
    var fallback = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return fallback }
    defer { freeifaddrs(ifaddr) }

    var wifi: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 else { continue }
        let ip = String(cString: host)
        if ip.hasPrefix("127.") { continue }
        let name = String(cString: interface.ifa_name)
        if name == "en0" {
            wifi = ip
        } else if fallback.hasPrefix("127.") {
            fallback = ip
        }
    }
    return wifi ?? fallback
}

final class VoiceHTTPServer {
    private weak var controller: AppController?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "voice.http")

    init(controller: AppController) {
        self.controller = controller
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: voiceListenPort) else { return }
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let url = "http://\(localIPv4()):\(voiceListenPort)"
                    DispatchQueue.main.async {
                        self.controller?.publishAddress(url)
                    }
                case .failed(let error):
                    fputs("Не вдалося відкрити порт \(voiceListenPort): \(error)\n", stderr)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        } catch {
            fputs("Не вдалося відкрити порт \(voiceListenPort): \(error)\n", stderr)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data {
                next.append(data)
            }
            let ready = next.range(of: Data("\r\n\r\n".utf8)) != nil || ((isComplete || error != nil) && !next.isEmpty)
            if ready {
                self.handle(next, connection: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func handle(_ data: Data, connection: NWConnection) {
        let request = parseHTTPRequestLine(data)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            let result: (Int, String)
            switch remoteAction(method: request.method, path: request.path) {
            case .start:
                result = self.controller?.startFromRemote() ?? (500, #"{"ok":false}"#)
            case .stop:
                result = self.controller?.stopFromRemote() ?? (500, #"{"ok":false}"#)
            case .reject:
                result = performRemote(method: request.method, path: request.path, phase: .idle, begin: { false }, finish: {})
            }
            self.respond(connection, code: result.0, body: result.1)
        }
    }

    private func respond(_ connection: NWConnection, code: Int, body: String) {
        connection.send(content: httpMessage(code: code, body: body), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

let app = NSApplication.shared
let controller = AppController()
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()
