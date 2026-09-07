import AppKit

/// Заголовок пункта в строке меню. Вынесен отдельно от AppDelegate, чтобы
/// его можно было отрисовать и проверить, не запуская всё приложение.
enum MenuBarTitle {

    static func color(_ s: VPNStatus) -> NSColor {
        switch s {
        case .connected:    return .systemGreen
        case .degraded:     return .systemOrange
        // Не жёлтый: на светлой строке меню он почти не виден. Серый
        // читается на обеих темах и не спорит с оранжевым «не отвечает».
        case .connecting, .disconnecting: return .systemGray
        case .disconnected: return .systemRed
        }
    }

    /// По короткой метке на каждый VPN, цвет = состояние. Одна иконка не
    /// смогла бы показать два независимых состояния, а пара меток читается
    /// мгновенно и занимает минимум места.
    static func make(_ vpns: [VPNRuntime]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, vpn) in vpns.enumerated() {
            if i > 0 {
                // Разрядка пошире обычного пробела, иначе «Am At» слипается
                // в одно слово.
                out.append(NSAttributedString(string: " ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .kern: 2.0,
                ]))
            }
            out.append(NSAttributedString(string: vpn.spec.badge, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color(vpn.status),
            ]))
        }
        return out
    }

    static func tooltip(_ vpns: [VPNRuntime]) -> String {
        vpns.map { "\($0.spec.title): \($0.status.title)" }.joined(separator: "\n")
    }
}
