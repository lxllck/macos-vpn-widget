import Foundation

/// Кольцевой буфер в памяти + файл ~/Library/Logs/VPNWidget.log.
/// Именно сюда попадает вывод openconnect/sshuttle — без него непонятно,
/// почему подключение не удалось (неверный OTP, недоступен сервер и т.д.).
final class Log {
    static let shared = Log()

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: String
        let text: String
    }

    private let queue = DispatchQueue(label: "vpnwidget.log")
    private var buffer: [Entry] = []
    private let maxEntries = 800
    private let fileURL: URL
    private var handle: FileHandle?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("VPNWidget.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    var path: String { fileURL.path }

    func info(_ s: String)  { add("INFO", s) }
    func warn(_ s: String)  { add("WARN", s) }
    func error(_ s: String) { add("ERR ", s) }

    private func add(_ level: String, _ text: String) {
        let entry = Entry(date: Date(), level: level, text: text)
        queue.async {
            self.buffer.append(entry)
            if self.buffer.count > self.maxEntries {
                self.buffer.removeFirst(self.buffer.count - self.maxEntries)
            }
            let stamp = Log.formatter.string(from: entry.date)
            if let d = "\(stamp) \(level) \(text)\n".data(using: .utf8) {
                self.handle?.write(d)
            }
        }
    }

    func snapshot() -> [Entry] { queue.sync { buffer } }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
