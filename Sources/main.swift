import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: VPNMonitor!

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.shared.info("VPN Widget запущен")
        Notifier.shared.requestAuthorization()

        let config = AppConfig.load()
        monitor = VPNMonitor(config: config)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController =
            NSHostingController(rootView: PanelView(monitor: monitor))

        monitor.onChange = { [weak self] in self?.refreshStatusItem() }
        monitor.start()
        refreshStatusItem()

    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = MenuBarTitle.make(monitor.vpns)
        button.toolTip = MenuBarTitle.tooltip(monitor.vpns)
    }

    /// Ставит панель под элемент строки меню.
    ///
    /// Своими силами, потому что NSPopover здесь игнорирует и якорный
    /// прямоугольник, и preferredEdge: замеры дали одно и то же положение
    /// для всех четырёх вариантов, причём панель перекрывала строку меню
    /// целиком и вылезала за верх экрана.
    private func anchorPopover(to button: NSStatusBarButton) {
        guard let view = popover.contentViewController?.view,
              let win = view.window,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let content = win.convertToScreen(view.convert(view.bounds, to: nil))
        // Вокруг содержимого есть прозрачное поле под тень — без его учёта
        // панель встанет со смещением на его толщину.
        let padTop = win.frame.maxY - content.maxY
        let padLeft = content.minX - win.frame.minX
        let visible = screen.visibleFrame

        // Верх содержимого — под строкой меню, даже если кнопка выше неё.
        let top = min(buttonRect.minY, visible.maxY) - 2
        var x = buttonRect.midX - content.width / 2 - padLeft
        // У края экрана панель сдвигается внутрь, а не обрезается.
        x = min(max(x, visible.minX + 6), visible.maxX - win.frame.width - 6)

        win.setFrameOrigin(NSPoint(x: x, y: top + padTop - win.frame.height))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        monitor.poll(forceProbe: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        anchorPopover(to: button)
        // Без активации поля ввода OTP не получают фокус клавиатуры.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// Управление автозапуском из командной строки — им же проверяется, что
// регистрация действительно прошла:
//   /Applications/VPNWidget.app/Contents/MacOS/VPNWidget --login-item status|on|off
if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
    let action = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "status"
    switch action {
    case "on":  LoginItem.set(true)
    case "off": LoginItem.set(false)
    default:    break
    }
    print("автозапуск: \(LoginItem.statusText)")
    exit(LoginItem.status == .enabled || action == "off" ? 0 : 1)
}

// NSApplication.delegate — weak-ссылка, поэтому делегат держим глобально.
nonisolated(unsafe) var retainedDelegate: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // без иконки в Dock
    app.run()
}
