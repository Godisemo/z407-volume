import Foundation
import os

/// Event trail written to the unified log, `~/Library/Logs/Z407Volume.log`, and kept in memory
/// for the menu's "Copy Diagnostics".
@MainActor
enum Diagnostics {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Z407Volume.log")
    static var onEvent: ((String) -> Void)?
    private(set) static var recent: [String] = []

    private static let logger = Logger(subsystem: "io.github.godisemo.z407-volume", category: "app")
    private static let maxRecent = 200
    private static let maxFileBytes = 1_000_000
    private static let handle = openFile()
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func record(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(timestamp.string(from: Date())) \(message)"
        recent.append(line)
        if recent.count > maxRecent { recent.removeFirst(recent.count - maxRecent) }
        handle?.write(Data((line + "\n").utf8))
        onEvent?(message)
    }

    private static func openFile() -> FileHandle? {
        let fm = FileManager.default
        let path = fileURL.path
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > maxFileBytes || !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        return handle
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
