import Foundation

/// Local persistence (Application Support JSON) for:
///  - the per-source "already reviewed" set of track URIs (discovery auto-skip, Phase 2)
///  - a cache of target-playlist membership (duplicate prevention)
@MainActor
final class ReviewHistory {
    private struct Store: Codable {
        var seenBySource: [String: Set<String>] = [:]
        var targetMembership: [String: Set<String>] = [:]

        /// Fold in a copy of the file written by another process. Both fields are grow-only on
        /// every path that merges, so a per-key union can't lose either side's work.
        mutating func formUnion(with other: Store) {
            seenBySource.merge(other.seenBySource) { $0.union($1) }
            targetMembership.merge(other.targetMembership) { $0.union($1) }
        }
    }

    private var store = Store()
    private let fileURL: URL

    /// The file's modification date as of our last read or write. A different value on disk means
    /// another process wrote in between — see `save(merging:)`.
    private var lastKnownModification: Date?

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

    /// Drop a track we just removed from the target. Without this the cache keeps claiming the
    /// song is "already in target" until the next full fetch, which is exactly the signal
    /// auto-skip reads — so a removed song would go on being skipped as a duplicate.
    func removeFromMembership(targetId: String, uri: String) {
        guard store.targetMembership[targetId]?.contains(uri) == true else { return }
        store.targetMembership[targetId]?.remove(uri)
        save(merging: false)
    }

    // MARK: Persistence
    private func load() {
        lastKnownModification = modificationDate()
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

    /// - Parameter merging: whether to fold in a concurrent writer's additions first.
    ///
    ///   Writes are already atomic, so the file can never be torn — but two processes each
    ///   holding a whole in-memory copy still means the second one to save silently discards
    ///   whatever the first added. `InstanceGuard` makes that nearly impossible now; this closes
    ///   the seconds-wide window while an outgoing copy is still winding down.
    ///
    ///   `removeFromMembership` passes `false`: a union would re-import the URI it just dropped,
    ///   and that cache is what auto-skip reads, so resurrecting an entry means going on skipping
    ///   a song the user deliberately took out of the target.
    private func save(merging: Bool = true) {
        if merging, let onDisk = concurrentlyWrittenStore() { store.formUnion(with: onDisk) }
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
        lastKnownModification = modificationDate()
    }

    /// The on-disk store, but only when someone else has written since we last touched the file.
    private func concurrentlyWrittenStore() -> Store? {
        guard let current = modificationDate(), current != lastKnownModification,
              let data = try? Data(contentsOf: fileURL),
              let onDisk = try? JSONDecoder().decode(Store.self, from: data)
        else { return nil }
        DebugLog.log("ReviewHistory: history.json changed underneath us; merging before save")
        return onDisk
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}
