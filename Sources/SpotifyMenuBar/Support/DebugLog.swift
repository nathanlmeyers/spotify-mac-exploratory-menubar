import Foundation

/// Appends timestamped diagnostics to ~/Library/Application Support/SpotifyMenuBar/debug.log.
/// File-based because this app's NSLog output isn't reliably captured by the unified log.
enum DebugLog {
    /// Roll at 10 MB, keeping one previous file.
    ///
    /// The log reached 41 MB / 440k lines once — four copies of the app plus every local test
    /// run all appending to it — at which point it had stopped being usable for the one thing it
    /// exists for: reconstructing what happened.
    private static let maxBytes: UInt64 = 10 * 1024 * 1024

    private static let queue = DispatchQueue(label: "SpotifyMenuBar.debuglog")

    private static let directory: URL = {
        // Under XCTest, write to a throwaway directory. The test target compiles this file, so
        // anything the suite logged used to land in the real production log — which is how
        // `NewReleaseStoreTests`' deliberately-corrupt fixtures came to read, months later, as
        // genuine corruption of the user's own state.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SpotifyMenuBarTests-logs", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyMenuBar", isDirectory: true)
    }()

    private static let fileURL: URL = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("debug.log")
    }()

    /// Both touched only from `queue`.
    private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Dated, not just HH:mm:ss — a log spanning weeks with bare clock times made
        // reconstructing a launch timeline far harder than it needed to be.
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        // Stamp at call time but format on the queue: `DateFormatter` isn't thread-safe, and the
        // interesting timestamp is when the event happened, not when the write drained.
        let now = Date()
        queue.async {
            guard let data = "\(formatter.string(from: now)) \(message)\n".data(using: .utf8) else { return }
            rotateIfNeeded()
            try? currentHandle()?.write(contentsOf: data)
        }
        NSLog("[SMB] %@", message)   // best-effort, in case the unified log does capture it
    }

    /// Block until everything already queued has been written.
    ///
    /// For the one caller that exits the process immediately afterwards — the single-instance
    /// stand-down in `main.swift` — where an async write would be lost and leave no record of
    /// why that copy quit.
    static func flush() {
        queue.sync {}
    }

    /// Opened `O_APPEND` so several processes can share one file safely. The previous
    /// seek-to-end-then-write was a read-modify-write race, and multiple copies of this app
    /// writing to one log is not hypothetical — it is what prompted all of this. With `O_APPEND`
    /// the kernel performs the seek and the write as one operation, so whole lines survive
    /// interleaving instead of overwriting each other.
    private static func currentHandle() -> FileHandle? {
        if let handle { return handle }
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return handle
    }

    private static func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes?[.size] as? UInt64, size >= maxBytes else { return }

        try? handle?.close()
        handle = nil
        let previous = directory.appendingPathComponent("debug.log.1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
    }
}
