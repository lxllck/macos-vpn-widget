import Foundation
import ServiceManagement
import AppKit

/// Автозапуск через SMAppService: приложение поднимается при входе в систему
/// (не при включении питания — строке меню нужна графическая сессия).
enum LoginItem {

    /// Вне бандла (например, в офскрин-рендере) SMAppService смысла не имеет.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static var status: SMAppService.Status {
        available ? SMAppService.mainApp.status : .notFound
    }

    static var isEnabled: Bool { status == .enabled }

    /// macOS может зарегистрировать автозапуск, но оставить его выключенным,
    /// если пользователь когда-то запретил его в Системных настройках.
    /// Молча считать это успехом нельзя — иначе галочка врёт.
    static var needsApproval: Bool { status == .requiresApproval }

    static var statusText: String {
        switch status {
        case .enabled:          return "включён"
        case .notRegistered:    return "выключен"
        case .requiresApproval: return "запрещён в Системных настройках"
        case .notFound:         return "недоступен"
        @unknown default:       return "неизвестно"
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard available else { return false }
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            Log.shared.info("Автозапуск: \(on ? "включён" : "выключен") — состояние \(statusText)")
            return true
        } catch {
            Log.shared.error("Автозапуск: \(error.localizedDescription)")
            return false
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
