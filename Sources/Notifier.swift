import Foundation
import UserNotifications
import AppKit

/// Уведомления о падении и переподключении. UNUserNotificationCenter
/// работает только для нормально собранного и подписанного бандла; если
/// система его не приняла — тихо уходим на osascript, чтобы пользователь
/// в любом случае увидел, что VPN упал.
final class Notifier {
    static let shared = Notifier()

    private var useUN = false
    private var asked = false

    private init() {}

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            Log.shared.warn("Нет bundle id — уведомления через osascript")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
            self?.asked = true
            self?.useUN = granted
            if let err {
                Log.shared.warn("Уведомления недоступны (\(err.localizedDescription)) — резерв osascript")
            } else if !granted {
                Log.shared.warn("Уведомления запрещены в системных настройках — резерв osascript")
            }
        }
    }

    func send(title: String, body: String) {
        Log.shared.info("Уведомление: \(title) — \(body)")
        guard useUN else { return fallback(title: title, body: body) }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { [weak self] err in
            if err != nil { self?.fallback(title: title, body: body) }
        }
    }

    private func fallback(title: String, body: String) {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let src = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", src]
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
