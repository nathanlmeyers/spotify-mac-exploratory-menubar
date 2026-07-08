import Foundation

/// Local persistence (Application Support JSON) for:
///  - the per-source "already reviewed" set of track URIs (discovery auto-skip, Phase 2)
///  - a cache of target-playlist membership (duplicate prevention)
@MainActor
final class ReviewHistory {
    private struct Store: Codable {
        var seenBySource: [String: Set<String>] = [:]
        var targetMembership: [String: Set<String>] = [:]
    }

    private var store = Store()
    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpotifyMenuBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: Reviewed set (Phase 2 discovery auto-skip)
    func markReviewed(sourceId: String, uri: String) {
        store.seenBySource[sourceId, default: []].insert(uri)
        save()
    }

    func hasReviewed(sourceId: String, uri: String) -> Bool {
        store.seenBySource[sourceId]?.contains(uri) ?? false
    }

    // MARK: Target membership cache (duplicate prevention)
    func cachedMembership(targetId: String) -> Set<String>? {
        store.targetMembership[targetId]
    }

    func setMembership(targetId: String, uris: Set<String>) {
        store.targetMembership[targetId] = uris
        save()
    }

    func addToMembership(targetId: String, uri: String) {
        store.targetMembership[targetId, default: []].insert(uri)
        save()
    }

    // MARK: Persistence
    private func load() {
        // File absent → legitimate first run; start empty.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            store = try JSONDecoder().decode(Store.self, from: data)
        } catch {
            // File exists but is unreadable (corrupt / partial write / schema change).
            // Preserve it before any save() overwrites it with the empty default.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? data.write(to: backup, options: .atomic)
            DebugLog.log("ReviewHistory: could not decode history.json (\(error)); backed up to \(backup.lastPathComponent), starting empty")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
