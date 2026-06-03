import Foundation

/// Appends timestamped diagnostics to ~/Library/Application Support/SpotifyMenuBar/debug.log.
/// File-based because this app's NSLog output isn't reliably captured by the unified log.
enum DebugLog {
    private static let queue = DispatchQueue(label: "SpotifyMenuBar.debuglog")

    private static let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    static func log(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
        NSLog("[SMB] %@", message)   // best-effort, in case the unified log does capture it
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
