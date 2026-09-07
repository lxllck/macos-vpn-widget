import Foundation

// MARK: - Описание того, что мы мониторим и чем управляем

/// TCP-проба: доказывает, что туннель реально несёт трафик, а не просто
/// что процесс жив. Для обоих VPN конечная точка — SSH, поэтому по
/// умолчанию ждём баннер "SSH-..." — это отсекает случай, когда
/// соединение принимается локально, но дальше не идёт.
struct ProbeSpec: Codable, Equatable {
    var host: String
    var port: Int
    var timeoutMs: Int
    var expectBanner: Bool
}

/// Один процесс, из которых состоит VPN. Сначала пробуем pid-файл,
/// затем — поиск по всей таблице процессов (pid-файл может протухнуть).
struct ProcSpec: Codable, Equatable {
    var label: String
    var pidFile: String?
    var pattern: String
}

/// Интерактивная аутентификация: шаги отвечаются строго по порядку,
/// поэтому два подряд идущих промпта "Password:" не перепутаются.
struct AuthSpec: Codable, Equatable {
    var user: String
    var passwordPrompt: String
    var otpPrompt: String
    var timeoutSec: Double
}

struct VPNSpec: Codable, Equatable {
    var id: String
    var title: String
    /// Метка в строке меню. Одной буквы не хватает: и Amnezia, и Aton
    /// начинаются на «A» и превращались в неразличимое «A A».
    var short: String?
    var command: String
    var startArgs: [String]
    var stopArgs: [String]
    var processes: [ProcSpec]
    var probe: ProbeSpec?
    var auth: AuthSpec?
    var autoReconnectAllowed: Bool

    var badge: String { short ?? String(title.prefix(2)) }
}

struct AppConfig: Codable {
    var pollIntervalSec: Double
    var probeIntervalSec: Double
    /// GUI-приложения стартуют с урезанным PATH, а sudo его ещё и сбрасывает
    /// (env_reset). Без этого скрипты не найдут sshuttle/openconnect.
    var childPath: String
    var vpns: [VPNSpec]

    static let defaults = AppConfig(
        pollIntervalSec: 5,
        probeIntervalSec: 15,
        childPath: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        vpns: [
            VPNSpec(
                id: "amnezia",
                title: "Amnezia",
                short: "Am",
                command: "/usr/local/bin/amnezia-vpn",
                startArgs: ["start"],
                stopArgs: ["stop"],
                processes: [
                    ProcSpec(label: "sshuttle",
                             pidFile: "/etc/vpnc/amnezia-sshuttle.pid",
                             pattern: #"sshuttle.*203\.0\.113\.10"#)
                ],
                probe: ProbeSpec(host: "203.0.113.10", port: 22,
                                 timeoutMs: 4000, expectBanner: true),
                auth: nil,
                autoReconnectAllowed: true
            ),
            VPNSpec(
                id: "aton",
                title: "Aton",
                short: "At",
                command: "/usr/local/bin/aton-vpn",
                startArgs: ["start"],
                stopArgs: ["stop"],
                processes: [
                    ProcSpec(label: "openconnect",
                             pidFile: nil,
                             pattern: #"openconnect.*vpn\.example\.com"#),
                    ProcSpec(label: "sshuttle",
                             pidFile: "/etc/vpnc/sshuttle.pid",
                             pattern: #"sshuttle.*10\.0\.0\.1"#)
                ],
                // 10.0.0.1 маршрутизируется только через utun -> успешный
                // коннект доказывает, что туннель openconnect действительно жив.
                probe: ProbeSpec(host: "10.0.0.1", port: 3389,
                                 timeoutMs: 5000, expectBanner: true),
                auth: AuthSpec(user: "your-user",
                               passwordPrompt: #"(?i)password"#,
                               otpPrompt: #"(?i)(otp|token|code|passcode|answer|password|second)"#,
                               timeoutSec: 120),
                // Требует свежий OTP — автоматически поднять нельзя.
                autoReconnectAllowed: false
            )
        ]
    )

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vpn-widget/config.json")
    }

    /// Читает конфиг из ~/.config/vpn-widget/config.json, создавая его при
    /// первом запуске. Любая ошибка — откат на встроенные значения, чтобы
    /// кривой JSON не оставил вас без виджета.
    static func load() -> AppConfig {
        let url = fileURL
        if let data = try? Data(contentsOf: url) {
            if let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
                return cfg
            }
            Log.shared.warn("config.json не разобран — использую значения по умолчанию")
            return .defaults
        }
        let cfg = AppConfig.defaults
        cfg.writeToDisk()
        return cfg
    }

    func writeToDisk() {
        let url = AppConfig.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(self) { try? data.write(to: url) }
    }
}
