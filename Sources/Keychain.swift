import Foundation
import Security

/// Пароль хранится в связке ключей macOS, а не в файле конфигурации.
/// OTP не хранится никогда — он одноразовый по определению.
enum Keychain {
    private static let service = "com.aleksey.vpnwidget"

    static func set(_ password: String, account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Сначала пробуем обновить существующую запись, иначе errSecDuplicateItem.
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }

    /// Проверяет только наличие записи, не читая сам пароль.
    ///
    /// Через get() делать это нельзя: kSecReturnData заставляет систему
    /// расшифровать значение, а расшифровка требует подтверждения доступа к
    /// связке ключей. Панель вызывает эту проверку при каждой отрисовке —
    /// из-за чего виджет просил пароль просто при открытии. Запрос одних
    /// атрибутов проходит молча.
    static func has(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }
}
