import AppKit
import Foundation
import Security

final class WifiSetupController: NSObject {
    private let service = "local.voicecursor.controller.wifi"
    private var window: NSWindow?
    private var ssidField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var statusLabel: NSTextField!
    private var flashButton: NSButton!
    private var flashing = false

    func hasSavedPassword() -> Bool {
        let password = savedNetwork().password ?? ""
        return !password.isEmpty
    }

    @objc func show(_ sender: Any?) {
        if window == nil {
            buildWindow()
        }
        let saved = savedNetwork()
        ssidField.stringValue = saved.ssid ?? "Xiaomi_4AEC"
        passwordField.stringValue = saved.password ?? ""
        statusLabel.stringValue = "Пароль лишається у в’язці ключів цього Mac."
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(passwordField)
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 248),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wi-Fi для плати"
        window.level = .floating
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let note = NSTextField(wrappingLabelWithString: "Введи пароль мережі 2.4 ГГц. Він не потрапляє в чат і не зберігається в git.")
        note.frame = NSRect(x: 20, y: 176, width: 400, height: 44)
        content.addSubview(note)

        let ssidLabel = NSTextField(labelWithString: "Мережа")
        ssidLabel.frame = NSRect(x: 20, y: 140, width: 70, height: 22)
        content.addSubview(ssidLabel)

        ssidField = NSTextField(frame: NSRect(x: 100, y: 138, width: 320, height: 24))
        content.addSubview(ssidField)

        let passwordLabel = NSTextField(labelWithString: "Пароль")
        passwordLabel.frame = NSRect(x: 20, y: 104, width: 70, height: 22)
        content.addSubview(passwordLabel)

        passwordField = NSSecureTextField(frame: NSRect(x: 100, y: 102, width: 320, height: 24))
        content.addSubview(passwordField)

        flashButton = NSButton(title: "Зберегти і прошити", target: self, action: #selector(saveAndFlash))
        flashButton.bezelStyle = .rounded
        flashButton.frame = NSRect(x: 100, y: 62, width: 180, height: 28)
        content.addSubview(flashButton)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 16, width: 400, height: 40)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        window.contentView = content
        self.window = window
    }

    @objc private func saveAndFlash() {
        guard !flashing else { return }
        let ssid = ssidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !ssid.isEmpty, !password.isEmpty else {
            statusLabel.stringValue = "Потрібні назва мережі і пароль."
            return
        }
        guard save(ssid: ssid, password: password) else {
            statusLabel.stringValue = "Не вдалося записати пароль у в’язку ключів."
            return
        }
        guard let port = serialPort() else {
            statusLabel.stringValue = "Пароль збережено. Підключи плату по USB."
            return
        }

        flashing = true
        flashButton.isEnabled = false
        statusLabel.stringValue = "Прошиваю плату…"
        let host = localIPv4()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.flash(ssid: ssid, password: password, host: host, port: port)
                ?? "Не вдалося прошити плату."
            DispatchQueue.main.async {
                self?.flashing = false
                self?.flashButton.isEnabled = true
                self?.statusLabel.stringValue = result.replacingOccurrences(of: password, with: "••••")
            }
        }
    }

    private func flash(ssid: String, password: String, host: String, port: String) -> String {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice/firmware/voice_button", isDirectory: true)
        let source = URL(fileURLWithPath: "/Users/mac/Documents/git/cursor-voice-assistant/esp32/voice_button/voice_button.ino")
        let sketch = support.appendingPathComponent("voice_button.ino")
        let secrets = support.appendingPathComponent("secrets.h")
        let cli = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voice/bin/arduino-cli")

        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: sketch)
        } catch {
            try? FileManager.default.removeItem(at: sketch)
            do {
                try FileManager.default.copyItem(at: source, to: sketch)
            } catch {
                return "Не знайдено прошивку плати."
            }
        }
        defer {
            try? FileManager.default.removeItem(at: secrets)
        }

        let header = """
        #pragma once
        #define WIFI_SSID_SECRET "\(cppString(ssid))"
        #define WIFI_PASSWORD_SECRET "\(cppString(password))"
        #define VOICE_HOST_SECRET "\(cppString(host))"

        """
        do {
            try header.write(to: secrets, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secrets.path)
        } catch {
            return "Не вдалося підготувати прошивку."
        }

        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            return "Не знайдено інструмент прошивки."
        }
        let fqbn = "esp32:esp32:esp32:UploadSpeed=115200"
        let compiled = run(cli, ["compile", "--fqbn", fqbn, support.path])
        guard compiled.status == 0 else {
            return "Компіляція не вдалась. \(tail(compiled.output))"
        }
        let uploaded = run(cli, ["upload", "-p", port, "--fqbn", fqbn, support.path])
        guard uploaded.status == 0 else {
            return "Плату не прошито. \(tail(uploaded.output))"
        }
        return "Плату прошито. Утримуй кнопку BOOT, щоб говорити."
    }

    private func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func tail(_ output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        if line.count <= 180 { return line }
        return String(line.suffix(180))
    }

    private func serialPort() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        guard let name = names.filter({ $0.hasPrefix("cu.usbserial") }).sorted().first else {
            return nil
        }
        return "/dev/\(name)"
    }

    private func savedNetwork() -> (ssid: String?, password: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let found = item as? [String: Any] else {
            return (nil, nil)
        }
        let ssid = found[kSecAttrAccount as String] as? String
        let password = (found[kSecValueData as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return (ssid, password)
    }

    private func save(ssid: String, password: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var query = base
        query[kSecAttrAccount as String] = ssid
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func cppString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
