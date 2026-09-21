import Foundation
import SwiftUI
import AppKit

enum VPNStatus: Equatable {
    case connected      // процессы живы и проба прошла
    case degraded       // что-то живо, но туннель не отвечает
    case connecting
    case disconnecting
    case disconnected

    var color: Color {
        switch self {
        case .connected:    return .green
        case .degraded:     return .orange
        case .connecting, .disconnecting: return .secondary
        case .disconnected: return .red
        }
    }
    var title: String {
        switch self {
        case .connected:     return "Подключён"
        case .degraded:      return "Туннель не отвечает"
        case .connecting:    return "Подключаю…"
        case .disconnecting: return "Отключаю…"
        case .disconnected:  return "Отключён"
        }
    }
}

struct ProcInfo: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let pid: pid_t?
    let ageSec: Int?
    var up: Bool { pid != nil }
    /// Через String, а не интерполяцией числа: иначе pid печатается
    /// с разделителем разрядов — "17 080".
    var pidText: String { pid.map { String($0) } ?? "—" }
}

struct VPNRuntime: Identifiable, Equatable {
    let spec: VPNSpec
    var id: String { spec.id }

    var status: VPNStatus = .disconnected
    var procs: [ProcInfo] = []
    var probeOK: Bool? = nil
    var probeDetail: String = ""
    var probeLatencyMs: Int = 0
    var lastProbeAt: Date? = nil
    var connectedSince: Date? = nil

    /// Возраст самого молодого из живых процессов — сколько туннель реально
    /// держится, независимо от того, когда запустился виджет.
    var uptimeSec: Int? {
        procs.filter { $0.up }.compactMap { $0.ageSec }.min()
    }
    var lastError: String? = nil
    /// Сервер отклонил вход — значит при следующей попытке надо спросить
    /// пароль заново, а не молча брать из связки ключей тот же неверный.
    var authFailed = false
    var busy = false

    /// Чего хочет пользователь. Автопереподключение работает только при
    /// desiredUp — иначе виджет воскрешал бы то, что вы сами выключили.
    var desiredUp = false
    var reconnectAttempts = 0
    var nextReconnectAt: Date? = nil

    var needsOTP: Bool { spec.auth != nil }
}

@MainActor
final class VPNMonitor: ObservableObject {

    @Published private(set) var vpns: [VPNRuntime] = []
    @Published var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }

    /// Пауза между попытками растёт — чтобы не долбить сервер, если он лежит.
    private let backoff: [TimeInterval] = [5, 15, 45, 120, 300]

    private let config: AppConfig
    /// Очереди разделены намеренно: подключение может выполняться минуту и
    /// более, а на общей последовательной очереди оно останавливало опрос —
    /// виджет замирал целиком и переставал показывать состояние.
    private let pollQueue = DispatchQueue(label: "vpnwidget.poll", qos: .utility)
    private let cmdQueue = DispatchQueue(label: "vpnwidget.cmd", qos: .userInitiated)
    private var timer: Timer?
    private var firstPollDone = false
    /// Сколько опросов подряд туннель в degraded — одиночный сбой пробы
    /// не должен дёргать перезапуск.
    private var degradedStreak: [String: Int] = [:]

    var onChange: (() -> Void)?

    init(config: AppConfig) {
        self.config = config
        let d = UserDefaults.standard
        self.autoReconnect = d.object(forKey: "autoReconnect") as? Bool ?? true
        self.vpns = config.vpns.map { VPNRuntime(spec: $0) }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    func start() {
        poll(forceProbe: true)
        timer = Timer.scheduledTimer(withTimeInterval: config.pollIntervalSec,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// После пробуждения сеть ещё не поднялась — сбрасываем счётчик попыток
    /// и даём паузу, иначе виджет сожжёт весь backoff впустую.
    private func handleWake() {
        Log.shared.info("Пробуждение из сна — пауза перед проверкой")
        for i in vpns.indices {
            vpns[i].reconnectAttempts = 0
            vpns[i].nextReconnectAt = Date().addingTimeInterval(10)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            Task { @MainActor in self?.poll(forceProbe: true) }
        }
    }

    // MARK: - Опрос

    private struct Observation {
        let id: String
        let procs: [ProcInfo]
        let probe: ProbeResult?
    }

    func poll(forceProbe: Bool = false) {
        let snapshot = vpns.map { ($0.spec, $0.lastProbeAt, $0.busy) }
        let interval = config.probeIntervalSec

        pollQueue.async { [weak self] in
            let table = Runner.processTable()
            var results: [Observation] = []

            for (spec, lastProbe, _) in snapshot {
                let procs = spec.processes.map { p -> ProcInfo in
                    let hit = Self.findPID(p, in: table)
                    return ProcInfo(label: p.label, pid: hit?.pid, ageSec: hit?.age)
                }
                let allUp = procs.allSatisfy { $0.up }
                var probe: ProbeResult? = nil
                if allUp, let ps = spec.probe {
                    let due = forceProbe || lastProbe == nil ||
                              Date().timeIntervalSince(lastProbe!) >= interval
                    if due { probe = Probe.check(ps) }
                }
                results.append(Observation(id: spec.id, procs: procs, probe: probe))
            }

            Task { @MainActor in self?.apply(results) }
        }
    }

    /// pid-файл — быстрый путь, но он переживает падение процесса и может
    /// указывать на чужой переиспользованный pid. Поэтому командная строка
    /// проверяется всегда, а при промахе идём искать по всей таблице.
    private nonisolated static func findPID(
        _ spec: ProcSpec,
        in table: [(pid: pid_t, age: Int, command: String)]) -> (pid: pid_t, age: Int)? {

        if let file = spec.pidFile,
           let raw = try? String(contentsOfFile: file, encoding: .utf8),
           let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let entry = table.first(where: { $0.pid == pid }),
           entry.command.range(of: spec.pattern, options: .regularExpression) != nil {
            return (pid, entry.age)
        }
        return table.first {
            !isObserver($0.command) &&
            $0.command.range(of: spec.pattern, options: .regularExpression) != nil
        }.map { ($0.pid, $0.age) }
    }

    /// Команды, которые сами упоминают искомый процесс и потому ложно
    /// совпадают с паттерном: `pkill -f sshuttle...`, `grep openconnect`,
    /// а также наша собственная sudo-обёртка запуска.
    private nonisolated static func isObserver(_ command: String) -> Bool {
        for marker in ["pgrep", "pkill", "/bin/ps", "ps -", "grep", "/usr/bin/env PATH="]
        where command.contains(marker) { return true }
        return false
    }

    private func apply(_ obs: [Observation]) {
        for o in obs {
            guard let i = vpns.firstIndex(where: { $0.id == o.id }) else { continue }
            let was = vpns[i].status
            vpns[i].procs = o.procs

            if let p = o.probe {
                vpns[i].probeOK = p.ok
                vpns[i].probeDetail = p.detail
                vpns[i].probeLatencyMs = p.latencyMs
                vpns[i].lastProbeAt = Date()
            }

            // Пока идёт наша собственная операция — не переписываем статус.
            if vpns[i].busy { continue }

            let up = o.procs.filter { $0.up }.count
            let total = o.procs.count
            let newStatus: VPNStatus
            if up == 0 {
                newStatus = .disconnected
            } else if up < total {
                newStatus = .degraded
            } else if vpns[i].spec.probe != nil {
                switch vpns[i].probeOK {
                case .some(true):  newStatus = .connected
                case .some(false): newStatus = .degraded
                // Свежей пробы ещё нет (только что перезапустили) — это не
                // повод объявлять аварию, ждём результата.
                case .none:        newStatus = .connecting
                }
            } else {
                newStatus = .connected
            }
            vpns[i].status = newStatus

            if newStatus == .connected {
                vpns[i].authFailed = false
                if vpns[i].connectedSince == nil { vpns[i].connectedSince = Date() }
                vpns[i].reconnectAttempts = 0
                vpns[i].nextReconnectAt = nil
                degradedStreak[o.id] = 0
            } else {
                vpns[i].connectedSince = nil
            }

            // На первом опросе намерение выводим из факта: если VPN уже
            // поднят до старта виджета — считаем, что он должен быть поднят.
            if !firstPollDone {
                vpns[i].desiredUp = (newStatus == .connected || newStatus == .degraded)
                Log.shared.info("\(vpns[i].spec.title) при старте: \(newStatus.title) — \(describe(vpns[i]))")
            } else if was != newStatus {
                announce(transition: was, to: newStatus, index: i)
            }

            evaluateReconnect(index: i, status: newStatus)
        }
        firstPollDone = true
        onChange?()
    }

    /// Компактная сводка для лога: какие процессы найдены и как прошла проба.
    private func describe(_ vpn: VPNRuntime) -> String {
        let procs = vpn.procs.map { $0.up ? "\($0.label) \($0.pidText)" : "\($0.label) нет" }
            .joined(separator: ", ")
        guard let ps = vpn.spec.probe, let ok = vpn.probeOK else { return procs }
        let verdict = ok ? "ok \(vpn.probeLatencyMs) мс, \(vpn.probeDetail)"
                         : "провал: \(vpn.probeDetail)"
        return "\(procs); проба \(ps.host):\(ps.port) \(verdict)"
    }

    private func announce(transition was: VPNStatus, to now: VPNStatus, index i: Int) {
        let name = vpns[i].spec.title
        Log.shared.info("\(name): \(was.title) -> \(now.title)")
        switch (was, now) {
        case (.connected, .degraded), (.connecting, .degraded):
            Notifier.shared.send(title: "\(name): туннель не отвечает",
                                 body: vpns[i].probeDetail.isEmpty
                                     ? "Процессы живы, но трафик не проходит"
                                     : vpns[i].probeDetail)
        case (.connected, .disconnected), (.degraded, .disconnected):
            Notifier.shared.send(title: "\(name) отключился",
                                 body: vpns[i].needsOTP
                                     ? "Нужно подключиться вручную — требуется OTP"
                                     : "Проверяю возможность переподключения")
        case (.degraded, .connected), (.disconnected, .connected):
            Notifier.shared.send(title: "\(name) подключён", body: "Соединение восстановлено")
        default:
            break
        }
    }

    // MARK: - Автопереподключение

    private func evaluateReconnect(index i: Int, status: VPNStatus) {
        var vpn = vpns[i]
        guard autoReconnect, vpn.spec.autoReconnectAllowed,
              vpn.desiredUp, !vpn.busy else { return }

        // degraded считаем падением только если он держится — одна
        // неудачная проба может быть просто дрогнувшей сетью.
        if status == .degraded {
            let streak = (degradedStreak[vpn.id] ?? 0) + 1
            degradedStreak[vpn.id] = streak
            guard streak >= 3 else { return }
        } else if status != .disconnected {
            return
        }

        guard vpn.reconnectAttempts < backoff.count else {
            if vpn.nextReconnectAt != nil {
                vpns[i].nextReconnectAt = nil
                Notifier.shared.send(
                    title: "\(vpn.spec.title): не удалось переподключить",
                    body: "Исчерпаны \(backoff.count) попытки. Подключите вручную.")
                Log.shared.error("\(vpn.spec.title): автопереподключение исчерпано")
            }
            return
        }

        if let next = vpn.nextReconnectAt {
            guard Date() >= next else { return }
        } else {
            vpns[i].nextReconnectAt = Date().addingTimeInterval(backoff[vpn.reconnectAttempts])
            return
        }

        vpn = vpns[i]
        let attempt = vpn.reconnectAttempts + 1
        vpns[i].reconnectAttempts = attempt
        vpns[i].nextReconnectAt = nil
        degradedStreak[vpn.id] = 0

        Notifier.shared.send(title: "\(vpn.spec.title): переподключаю",
                             body: "Попытка \(attempt) из \(backoff.count)")
        Log.shared.info("\(vpn.spec.title): автопереподключение, попытка \(attempt)")

        Task { await self.reconnect(id: vpn.id, wasDegraded: status == .degraded) }
    }

    private func reconnect(id: String, wasDegraded: Bool) async {
        // Подвисший туннель надо сначала снять, иначе start увидит живой
        // pid и решит, что всё уже работает.
        if wasDegraded { await stop(id: id, userInitiated: false) }
        await connect(id: id, otp: nil, userInitiated: false)
    }

    // MARK: - Действия

    private func argv(for spec: VPNSpec, args: [String]) -> [String] {
        // sudo -n: пароль настроен как NOPASSWD, так что запрос пароля тут
        // означал бы зависший процесс — пусть лучше сразу упадёт с ошибкой.
        ["/usr/bin/sudo", "-n", "/usr/bin/env", "PATH=\(config.childPath)",
         spec.command] + args
    }

    func connect(id: String, otp: String?, userInitiated: Bool = true) async {
        guard let i = vpns.firstIndex(where: { $0.id == id }), !vpns[i].busy else { return }
        let spec = vpns[i].spec
        vpns[i].busy = true
        vpns[i].status = .connecting
        vpns[i].lastError = nil
        if userInitiated {
            vpns[i].desiredUp = true
            vpns[i].reconnectAttempts = 0
            vpns[i].nextReconnectAt = nil
        }
        onChange?()

        var steps: [AnswerStep] = []
        var timeout: Double = 90
        if let auth = spec.auth {
            guard let otp, !otp.isEmpty else {
                finish(i, error: "Нужен код OTP")
                return
            }
            let password = Keychain.get(account: auth.user) ?? ""
            guard !password.isEmpty else {
                finish(i, error: "Пароль не сохранён в связке ключей")
                return
            }
            steps = [AnswerStep(pattern: auth.passwordPrompt, reply: password, secret: true),
                     AnswerStep(pattern: auth.otpPrompt, reply: otp, secret: true)]
            timeout = auth.timeoutSec
        }

        let cmd = argv(for: spec, args: spec.startArgs)
        Log.shared.info("\(spec.title): запуск \(spec.command) \(spec.startArgs.joined(separator: " "))")

        let title = spec.title
        let result = await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
            cmdQueue.async {
                Self.prepareSSHKeys(spec)
                c.resume(returning: Runner.runPTY(
                    argv: cmd, env: ["PATH": self.config.childPath],
                    answers: steps, failurePattern: spec.auth?.failureRegex,
                    timeout: timeout,
                    // Пишем по мере поступления: если подключение зависнет,
                    // только это и покажет, на каком промпте оно стоит.
                    onOutput: { Log.shared.info("  \(title)| \($0)") }))
            }
        }

        vpns[i].authFailed = result.failureReason != nil

        var error: String? = nil
        if result.timedOut {
            error = "Таймаут подключения (\(Int(timeout)) с). Смотрите лог."
        } else if !result.succeeded {
            error = Self.explain(result, spec: spec)
        }
        finish(i, error: error)
    }

    /// Загружает ключи в ssh-agent перед запуском.
    ///
    /// Виджет работает от имени пользователя, поэтому связка ключей ему
    /// доступна и парольная фраза берётся оттуда молча. Запускаемому под
    /// sudo sshuttle связка уже недоступна — ему остаётся только агент,
    /// а тот пуст после каждой перезагрузки. Команда идемпотентна, так что
    /// вызывать её перед каждым подключением безопасно.
    private nonisolated static func prepareSSHKeys(_ spec: VPNSpec) {
        for raw in spec.sshKeys ?? [] {
            let path = NSString(string: raw).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                Log.shared.warn("\(spec.title): ключ \(path) не найден")
                continue
            }
            // SSH_ASKPASS_REQUIRE=never — чтобы при отсутствии фразы в связке
            // ключей команда сразу упала, а не полезла спрашивать.
            let r = Runner.run(argv: ["/usr/bin/ssh-add", "--apple-use-keychain", path],
                               env: ["SSH_ASKPASS_REQUIRE": "never"], timeout: 15)
            if r.succeeded {
                Log.shared.info("\(spec.title): ключ \(path) загружен в ssh-agent")
            } else {
                Log.shared.warn("\(spec.title): ключ \(path) не загружен — \(r.output)")
            }
        }
    }

    /// Вывод openconnect многословный — вытаскиваем то, что объясняет отказ.
    private static func explain(_ r: RunResult, spec: VPNSpec) -> String {
        // Отказ сервера — самая частая причина, и он должен называться
        // прямо, а не прятаться за «код возврата» или таймаутом.
        if let reason = r.failureReason {
            return "Сервер отклонил вход: \(reason) Проверьте пароль и код OTP."
        }
        let out = r.output.lowercased()
        if out.contains("a password is required") || out.contains("sudo:") {
            return "sudo отказал в правах — проверьте NOPASSWD в /etc/sudoers"
        }
        if out.contains("login failed") || out.contains("authentication failure")
            || out.contains("invalid") {
            return "Аутентификация не прошла — проверьте пароль и OTP"
        }
        if out.contains("permission denied (publickey") || out.contains("failed to establish ssh session") {
            return "SSH-ключ не принят. Обычно после перезагрузки — ключ с парольной фразой пропал из ssh-agent."
        }
        if out.contains("command not found") {
            return "Не найден sshuttle/openconnect — проверьте PATH в config.json"
        }
        if r.killFailed {
            return "Процесс завис и не снимается — проверьте лог и pkill openconnect"
        }
        if r.unansweredPrompt {
            return "Промпт не распознан — точный текст в логе, шаблон правится в config.json"
        }
        let tail = r.output.split(separator: "\n").suffix(2).joined(separator: " ")
        return tail.isEmpty ? "Код возврата \(r.exitCode)" : String(tail.prefix(160))
    }

    func stop(id: String, userInitiated: Bool = true) async {
        guard let i = vpns.firstIndex(where: { $0.id == id }), !vpns[i].busy else { return }
        let spec = vpns[i].spec
        vpns[i].busy = true
        vpns[i].status = .disconnecting
        if userInitiated {
            vpns[i].desiredUp = false
            vpns[i].nextReconnectAt = nil
            vpns[i].reconnectAttempts = 0
        }
        onChange?()

        let cmd = argv(for: spec, args: spec.stopArgs)
        Log.shared.info("\(spec.title): остановка")
        let title = spec.title
        _ = await withCheckedContinuation { (c: CheckedContinuation<RunResult, Never>) in
            cmdQueue.async {
                c.resume(returning: Runner.runPTY(
                    argv: cmd, env: ["PATH": self.config.childPath],
                    answers: [], timeout: 30,
                    onOutput: { Log.shared.info("  \(title)| \($0)") }))
            }
        }
        // pkill возвращает 1, если убивать было нечего — это не ошибка.
        finish(i, error: nil)
    }

    private func finish(_ i: Int, error: String?) {
        vpns[i].busy = false
        vpns[i].lastError = error
        // Проба, снятая до перезапуска, больше ничего не описывает. Если её
        // не сбросить, ближайший опрос объявит ложную тревогу по устаревшим
        // данным — ровно то, ради чего этот виджет и делается.
        vpns[i].probeOK = nil
        vpns[i].lastProbeAt = nil
        if let e = error { Log.shared.error("\(vpns[i].spec.title): \(e)") }
        onChange?()
        poll(forceProbe: true)
    }

    var summary: [(title: String, status: VPNStatus)] {
        vpns.map { ($0.spec.title, $0.status) }
    }
}
