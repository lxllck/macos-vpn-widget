import Foundation
import Darwin

struct ProbeResult {
    let ok: Bool
    let latencyMs: Int
    let detail: String
}

/// Проверка «трафик реально ходит», а не «процесс числится живым».
/// Это ровно тот случай, который сейчас не виден: sshuttle/openconnect
/// остаются в списке процессов, а туннель уже мёртв.
enum Probe {

    static func check(_ spec: ProbeSpec) -> ProbeResult {
        let start = Date()
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(spec.host, String(spec.port), &hints, &info) == 0,
              let ai = info else {
            return ProbeResult(ok: false, latencyMs: 0, detail: "имя не разрешается")
        }
        defer { freeaddrinfo(info) }

        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else {
            return ProbeResult(ok: false, latencyMs: 0, detail: "нет сокета")
        }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let deadline = Date().addingTimeInterval(Double(spec.timeoutMs) / 1000.0)

        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else {
                return ProbeResult(ok: false, latencyMs: ms(start), detail: err())
            }
            guard waitFor(fd, events: Int16(POLLOUT), deadline: deadline) else {
                return ProbeResult(ok: false, latencyMs: ms(start), detail: "таймаут коннекта")
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            guard soErr == 0 else {
                return ProbeResult(ok: false, latencyMs: ms(start),
                                   detail: String(cString: strerror(soErr)))
            }
        }

        guard spec.expectBanner else {
            return ProbeResult(ok: true, latencyMs: ms(start), detail: "порт открыт")
        }

        // Порт может принимать соединение локально (sshuttle слушает), но не
        // отдавать ничего с той стороны. Ждём реальный ответ сервера.
        guard waitFor(fd, events: Int16(POLLIN), deadline: deadline) else {
            return ProbeResult(ok: false, latencyMs: ms(start), detail: "нет ответа сервера")
        }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else {
            return ProbeResult(ok: false, latencyMs: ms(start), detail: "соединение закрыто")
        }
        let banner = String(decoding: buf[0..<min(n, 24)], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProbeResult(ok: true, latencyMs: ms(start), detail: banner)
    }

    private static func waitFor(_ fd: Int32, events: Int16, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var p = pollfd(fd: fd, events: events, revents: 0)
        return poll(&p, 1, Int32(remaining * 1000)) > 0 && (p.revents & events) != 0
    }

    private static func ms(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }
    private static func err() -> String { String(cString: strerror(errno)) }
}
