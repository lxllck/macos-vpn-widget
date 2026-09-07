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

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.poll(forceProbe: true)
            // Без активации поля ввода OTP не получают фокус клавиатуры.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
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
