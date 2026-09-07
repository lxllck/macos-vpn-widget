import Foundation
import Darwin

/// Один шаг интерактивного диалога: regex промпта -> что отправить.
/// Шаги отвечаются строго по порядку — так два одинаковых промпта
/// "Password:" подряд получат разные ответы.
struct AnswerStep {
    let pattern: String
    let reply: String
    /// Не попадёт ни в лог, ни в UI.
    let secret: Bool
}

struct RunResult {
    let exitCode: Int32
    let output: String
    let timedOut: Bool
    let unansweredPrompt: Bool
    /// Процесс не удалось снять даже через sudo — о таком надо сказать
    /// вслух, иначе рядом останется висеть чужой openconnect.
    var killFailed: Bool = false
    var succeeded: Bool { exitCode == 0 && !timedOut }
}

enum Runner {

    /// Запускает команду в псевдотерминале.
    ///
    /// PTY нужен по двум причинам: openconnect выключает эхо через tcsetattr
    /// и читает пароль только с tty, а sudo в некоторых конфигурациях
    /// отказывается работать без терминала.
    ///
    /// Ждём завершения именно прямого потомка, а не EOF на мастере:
    /// openconnect --background и sshuttle -D демонизируются и продолжают
    /// держать tty открытым, так что EOF не наступит никогда.
    static func runPTY(argv: [String],
                       env extraEnv: [String: String],
                       answers: [AnswerStep],
                       timeout: Double,
                       onOutput: ((String) -> Void)? = nil) -> RunResult {

        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0,
              let sname = ptsname(master) else {
            return RunResult(exitCode: -1, output: "не удалось выделить псевдотерминал",
                             timedOut: false, unansweredPrompt: false)
        }
        let slavePath = String(cString: sname)
        close(slave)  // потомок откроет его сам и получит управляющий терминал

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        defer { posix_spawn_file_actions_destroy(&fa) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // SETSID: потомок становится лидером сессии, и открытый slave
        // становится его управляющим терминалом.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attr) }

        var environment = ProcessInfo.processInfo.environment
        extraEnv.forEach { environment[$0.key] = $0.value }
        let envStrings = environment.map { "\($0.key)=\($0.value)" }

        let cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            cargv.forEach { if let p = $0 { free(p) } }
            cenv.forEach { if let p = $0 { free(p) } }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cargv, cenv)
        guard rc == 0 else {
            close(master)
            return RunResult(exitCode: -1,
                             output: "не удалось запустить \(argv[0]): \(String(cString: strerror(rc)))",
                             timedOut: false, unansweredPrompt: false)
        }

        // --- поток чтения: копит вывод и отвечает на промпты ---
        let lock = NSLock()
        var collected = ""
        var tail = ""
        var pending = answers
        let readerDone = DispatchSemaphore(value: 0)

        let redact: (String) -> String = { text in
            var t = text
            for step in answers where step.secret && !step.reply.isEmpty {
                t = t.replacingOccurrences(of: step.reply, with: "•••")
            }
            return t
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 4096)
            var lineBuf = ""
            while true {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }   // мастер закрыт или потомок ушёл
                // Приводим переводы строк сразу на входе. Псевдотерминал
                // отдаёт "\r\n", а Swift считает это одним символом, не
                // равным "\n": без нормализации не работают ни поиск строк,
                // ни проверка «вывод не заканчивается переводом строки»,
                // по которой мы отличаем промпт от обычного сообщения.
                let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                lock.lock()
                collected += chunk
                tail += chunk
                lineBuf += chunk

                // Сначала снимаем из буфера все завершённые строки — тогда
                // в lineBuf остаётся ровно незавершённый хвост, то есть
                // потенциальный промпт.
                var lines: [String] = []
                while let nl = lineBuf.firstIndex(of: "\n") {
                    let line = String(lineBuf[lineBuf.startIndex..<nl])
                        .trimmingCharacters(in: .whitespaces)
                    lineBuf = String(lineBuf[lineBuf.index(after: nl)...])
                    if !line.isEmpty { lines.append(line) }
                }

                // Отвечаем, только когда программа действительно ждёт ввода.
                // Настоящий промпт не заканчивается переводом строки, а
                // информационные строки — заканчиваются. Это принципиально:
                // openconnect печатает "Please enter your username and
                // password." задолго до промпта "Password:", и ответ на неё
                // уходил в пустоту — перед запросом пароля openconnect делает
                // tcsetattr(TCSAFLUSH) и отбрасывает всё, что пришло раньше.
                var answered: String? = nil
                if let step = pending.first,
                   !tail.hasSuffix("\n"),
                   tail.range(of: step.pattern, options: .regularExpression) != nil {
                    let reply = step.reply + "\n"
                    _ = reply.withCString { write(master, $0, strlen($0)) }
                    pending.removeFirst()
                    answered = lineBuf.trimmingCharacters(in: .whitespaces)
                    tail = ""
                    lineBuf = ""
                }
                if tail.count > 4096 { tail = String(tail.suffix(2048)) }
                lock.unlock()

                // Пишем в лог по мере поступления, а не одним куском в конце:
                // при зависании только это и показывает, на чём мы стоим.
                for line in lines { onOutput?(redact(line)) }
                if let prompt = answered {
                    onOutput?("[промпт «\(prompt)» — ответ отправлен]")
                }
            }
            readerDone.signal()
        }

        // --- ожидание потомка с таймаутом ---
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var timedOut = false
        var killed = true
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0 { break }
            if Date() >= deadline {
                timedOut = true
                onOutput?("[таймаут — снимаю процесс]")
                killed = terminate(group: pid)
                break
            }
            usleep(50_000)
        }

        close(master)                       // разблокирует read() в потоке чтения
        _ = readerDone.wait(timeout: .now() + 2)

        lock.lock()
        var out = collected
        let leftover = pending.count
        lock.unlock()

        // Секреты (в т.ч. эхо OTP из терминала) не должны попасть в лог.
        for step in answers where step.secret && !step.reply.isEmpty {
            out = out.replacingOccurrences(of: step.reply, with: "•••")
        }
        out = out.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")

        let code: Int32 = timedOut ? -2 :
            (status & 0x7f) == 0 ? (status >> 8) & 0xff : -(status & 0x7f)

        return RunResult(exitCode: code, output: out.trimmingCharacters(in: .whitespacesAndNewlines),
                         timedOut: timedOut, unansweredPrompt: leftover > 0,
                         killFailed: !killed)
    }

    /// Снимает всю группу процессов и дожидается её исчезновения.
    ///
    /// Два момента, на которых прошлая версия ломалась насмерть:
    /// потомок — это sudo, то есть root, и обычный kill от имени пользователя
    /// возвращает EPERM; а безусловный `waitpid(pid, &status, 0)` после
    /// неудачного kill блокировал очередь навсегда и вешал весь виджет.
    /// Поэтому снимаем через sudo и ждём строго ограниченное время.
    @discardableResult
    private static func terminate(group pid: pid_t) -> Bool {
        // Отрицательный pid = вся группа: сам скрипт уже мог породить
        // собственный `sudo openconnect`, который иначе остался бы сиротой.
        for signal in ["-TERM", "-KILL"] {
            _ = runQuiet(["/usr/bin/sudo", "-n", "/bin/kill", signal, "-\(pid)"])
            _ = runQuiet(["/usr/bin/sudo", "-n", "/bin/kill", signal, "\(pid)"])
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                var st: Int32 = 0
                if waitpid(pid, &st, WNOHANG) == pid { return true }
                if kill(pid, 0) != 0 && errno == ESRCH { return true }
                usleep(100_000)
            }
        }
        return false
    }

    /// Короткая вспомогательная команда без псевдотерминала.
    @discardableResult
    private static func runQuiet(_ argv: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Полная таблица процессов одним вызовом — дешевле, чем дёргать
    /// ps/pgrep отдельно для каждого процесса на каждом опросе.
    /// etime даёт настоящий возраст туннеля, а не время с запуска виджета.
    static func processTable() -> [(pid: pid_t, age: Int, command: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,etime=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            var s = Substring(line).drop { $0 == " " }
            guard let a = s.firstIndex(of: " "), let pid = pid_t(s[s.startIndex..<a]) else { return nil }
            s = s[a...].drop { $0 == " " }
            guard let b = s.firstIndex(of: " ") else { return nil }
            let age = parseETime(String(s[s.startIndex..<b]))
            let cmd = String(s[b...].drop { $0 == " " })
            return (pid, age, cmd)
        }
    }

    /// ps печатает etime как [[dd-]hh:]mm:ss.
    private static func parseETime(_ s: String) -> Int {
        var days = 0, rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Int(s[s.startIndex..<dash]) ?? 0
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        let hms: Int
        switch parts.count {
        case 3: hms = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: hms = parts[0] * 60 + parts[1]
        default: return days * 86400
        }
        return days * 86400 + hms
    }
}
