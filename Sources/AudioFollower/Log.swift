import Foundation

// Writes timestamped lines to ~/Library/Logs/AudioFollower.log.
// Unified-log output from ad-hoc-signed apps is suppressed on recent macOS,
// so we roll our own to make debugging feasible.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AudioFollower.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        }
    }
}
