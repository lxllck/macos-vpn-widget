import Foundation
import ServiceManagement

enum LoginItem {
    /// Вне бандла (например, в офскрин-рендере) SMAppService смысла не имеет.
    static var isEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            Log.shared.error("Автозапуск: \(error.localizedDescription)")
            return false
        }
    }
}
