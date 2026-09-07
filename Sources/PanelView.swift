import SwiftUI

struct PanelView: View {
    @ObservedObject var monitor: VPNMonitor

    /// id VPN, для которого сейчас запрашиваем OTP (nil — форма скрыта).
    @State private var authTarget: String? = nil
    @State private var otp = ""
    @State private var password = ""
    @State private var needPassword = false
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ForEach(monitor.vpns) { vpn in
                row(vpn)
                Divider()
            }
            footer
        }
        .frame(width: 340)
        // Автозапуск можно выключить и снаружи — в Системных настройках,
        // поэтому состояние галочки перечитываем при каждом открытии панели.
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            loginNeedsApproval = LoginItem.needsApproval
        }
    }

    // MARK: Заголовок

    private var header: some View {
        HStack {
            Text("VPN").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                monitor.poll(forceProbe: true)
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Проверить сейчас")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Строка одного VPN

    @ViewBuilder
    private func row(_ vpn: VPNRuntime) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(vpn.status.color).frame(width: 8, height: 8)
                Text(vpn.spec.title).font(.system(size: 13, weight: .medium))
                Spacer()
                if vpn.busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
                Text(vpn.status.title)
                    .font(.system(size: 11))
                    .foregroundStyle(vpn.status == .connected ? .secondary : .primary)
            }

            detail(vpn)

            if let e = vpn.lastError {
                Text(e)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if authTarget == vpn.id {
                authForm(vpn)
            } else {
                actions(vpn)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder
    private func detail(_ vpn: VPNRuntime) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                ForEach(vpn.procs) { p in
                    Text("\(p.label) \(p.pidText)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(p.up ? .secondary : Color.red)
                }
            }
            if let ok = vpn.probeOK {
                let t = vpn.spec.probe.map { "\($0.host):\($0.port)" } ?? ""
                Text(ok ? "проба \(t) · \(vpn.probeLatencyMs) мс · \(vpn.probeDetail)"
                        : "проба \(t) не прошла · \(vpn.probeDetail)")
                    .font(.system(size: 10))
                    .foregroundStyle(ok ? .secondary : Color.orange)
                    .lineLimit(1)
            }
            if let up = vpn.uptimeSec, vpn.status == .connected || vpn.status == .degraded {
                Text("на связи \(Self.uptime(up))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let next = vpn.nextReconnectAt, vpn.status != .connected {
                Text("переподключение через \(max(0, Int(next.timeIntervalSinceNow))) с")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func actions(_ vpn: VPNRuntime) -> some View {
        HStack(spacing: 8) {
            if vpn.status == .disconnected {
                Button("Подключить") { beginConnect(vpn) }
                    .disabled(vpn.busy)
            } else {
                Button("Отключить") { Task { await monitor.stop(id: vpn.id) } }
                    .disabled(vpn.busy)
                if vpn.status == .degraded {
                    Button("Перезапустить") {
                        Task {
                            await monitor.stop(id: vpn.id, userInitiated: false)
                            beginConnect(vpn)
                        }
                    }
                    .disabled(vpn.busy)
                }
            }
            Spacer()
        }
        .controlSize(.small)
    }

    /// Форма аутентификации для Aton. Пароль спрашивается только если его
    /// ещё нет в связке ключей; OTP — всегда, он одноразовый.
    @ViewBuilder
    private func authForm(_ vpn: VPNRuntime) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if needPassword {
                SecureField("Пароль \(vpn.spec.auth?.user ?? "")", text: $password)
                    .textFieldStyle(.roundedBorder)
                Text("Сохранится в связке ключей macOS, спросим один раз.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            TextField("Код OTP", text: $otp)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitAuth(vpn) }
            HStack {
                Button("Подключить") { submitAuth(vpn) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(otp.isEmpty || (needPassword && password.isEmpty))
                Button("Отмена") { resetAuth() }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    // MARK: Низ панели

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Автоматически поднимать Amnezia", isOn: $monitor.autoReconnect)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 3) {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: launchAtLogin) { _, v in
                        LoginItem.set(v)
                        // Показываем то, что реально записала система,
                        // а не то, что мы у неё попросили.
                        launchAtLogin = LoginItem.isEnabled
                        loginNeedsApproval = LoginItem.needsApproval
                    }
                if loginNeedsApproval {
                    HStack(spacing: 6) {
                        Text("Запрещён в Системных настройках")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                        Button("Открыть") { LoginItem.openSystemSettings() }
                            .controlSize(.mini)
                    }
                }
            }

            HStack(spacing: 10) {
                if let auth = monitor.vpns.compactMap({ $0.spec.auth }).first {
                    if Keychain.has(account: auth.user) {
                        Button("Изменить пароль") { beginPasswordChange(auth) }
                        Button("Удалить пароль") {
                            Keychain.delete(account: auth.user)
                            monitor.objectWillChange.send()
                        }
                    } else {
                        Text("пароль Aton не сохранён")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .controlSize(.small)

            HStack(spacing: 10) {
                Button("Лог") {
                    NSWorkspace.shared.selectFile(Log.shared.path,
                                                  inFileViewerRootedAtPath: "")
                }
                Button("Настройки") {
                    NSWorkspace.shared.selectFile(AppConfig.fileURL.path,
                                                  inFileViewerRootedAtPath: "")
                }
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Логика

    private func beginConnect(_ vpn: VPNRuntime) {
        guard let auth = vpn.spec.auth else {
            Task { await monitor.connect(id: vpn.id, otp: nil) }
            return
        }
        // После отказа сервера пароль из связки ключей заведомо не подошёл —
        // спрашиваем заново, иначе повторили бы ту же неверную попытку.
        needPassword = !Keychain.has(account: auth.user) || vpn.authFailed
        otp = ""; password = ""
        authTarget = vpn.id
    }

    /// Открывает форму с полем пароля, не дожидаясь неудачной попытки.
    private func beginPasswordChange(_ auth: AuthSpec) {
        guard let vpn = monitor.vpns.first(where: { $0.spec.auth?.user == auth.user })
        else { return }
        otp = ""; password = ""
        needPassword = true
        authTarget = vpn.id
    }

    private func submitAuth(_ vpn: VPNRuntime) {
        guard let auth = vpn.spec.auth else { return }
        if needPassword && !password.isEmpty {
            if !Keychain.set(password, account: auth.user) {
                Log.shared.error("Не удалось записать пароль в связку ключей")
            }
        }
        let code = otp
        resetAuth()
        Task { await monitor.connect(id: vpn.id, otp: code) }
    }

    private func resetAuth() {
        authTarget = nil; otp = ""; password = ""; needPassword = false
    }

    private static func uptime(_ s: Int) -> String {
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \((s % 3600) / 60) мин"
    }
}
