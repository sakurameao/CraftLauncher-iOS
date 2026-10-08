import Foundation
import Combine

/// A single console line.
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let level: LogConsole.Level
    let text: String

    /// `HH:mm:ss` — the colon-separated form players recognise from the official
    /// launcher, not a locale-dependent rendering.
    var timestamp: String {
        LogEntry.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Observable log bus.
///
/// Two consumers exist: the SwiftUI console (`entries`) and the raw
/// `logs/console.log` file that survives app termination. The ring buffer is
/// bounded so a chatty Forge launch cannot exhaust memory — the JVM can emit tens
/// of thousands of lines and SwiftUI diffing that many rows would stall the UI.
final class LogConsole: ObservableObject {
    static let shared = LogConsole()

    enum Level: String, Comparable {
        case trace, debug, info, warning, error, game

        var rank: Int {
            switch self {
            case .trace: return 0
            case .debug: return 1
            case .info: return 2
            case .game: return 3
            case .warning: return 4
            case .error: return 5
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        /// Single-character gutter marker, matching the compact style used by
        /// server consoles.
        var glyph: String {
            switch self {
            case .trace: return "·"
            case .debug: return "·"
            case .info: return "›"
            case .game: return " "
            case .warning: return "!"
            case .error: return "✗"
            }
        }
    }

    /// Bounded at 6000 lines. Older lines are still on disk if the user needs them.
    private static let bufferLimit = 6000

    @Published private(set) var entries: [LogEntry] = []

    /// Set by the UI to pause auto-scroll while the user reads history.
    @Published var autoScroll = true

    private let queue = DispatchQueue(label: "com.craftlauncher.log", qos: .utility)
    private var fileHandle: FileHandle?
    private let publishSubject = PassthroughSubject<LogEntry, Never>()

    /// High-volume publishers (the JVM pipe) subscribe here and coalesce on their
    /// own schedule instead of triggering a `@Published` update per line.
    var stream: AnyPublisher<LogEntry, Never> { publishSubject.eraseToAnyPublisher() }

    private init() {
        openLogFile()
    }

    private func openLogFile() {
        LauncherPath.ensureDirectory(LauncherPath.logs)
        let url = LauncherPath.consoleLog
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    /// Appends one line. Safe to call from any thread.
    func append(_ level: Level, _ text: String) {
        let entry = LogEntry(date: Date(), level: level, text: text)

        queue.async { [weak self] in
            guard let self else { return }
            self.writeToFile(entry)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries.append(entry)
            if self.entries.count > Self.bufferLimit {
                self.entries.removeFirst(self.entries.count - Self.bufferLimit)
            }
            self.publishSubject.send(entry)
        }
    }

    func info(_ text: String) { append(.info, text) }
    func warning(_ text: String) { append(.warning, text) }
    func error(_ text: String) { append(.error, text) }

    private func writeToFile(_ entry: LogEntry) {
        let line = "[\(entry.timestamp)] [\(entry.level.rawValue.uppercased())] \(entry.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            // Losing the file mirror is not worth crashing over; the in-memory
            // buffer still has the line.
            fileHandle = nil
        }
    }

    /// Truncates the on-disk log and clears the buffer. Called before each launch so
    /// `console.log` describes exactly one run.
    func reset() {
        queue.sync {
            try? fileHandle?.close()
            FileManager.default.createFile(atPath: LauncherPath.consoleLog.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: LauncherPath.consoleLog)
        }
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }

    /// Full transcript as text, for the share sheet / crash report bundle.
    func transcript() -> String {
        entries.map { "[\($0.timestamp)] [\($0.level.rawValue.uppercased())] \($0.text)" }
            .joined(separator: "\n")
    }
}
