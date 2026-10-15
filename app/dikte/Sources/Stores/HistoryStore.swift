import Foundation
import Observation

/// history.json — newest first. Trimmed to `settings.historyLimit` (0 = unlimited) on add.
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored var limit: () -> Int = { 0 }

    @ObservationIgnored private let url: URL

    private struct File: Codable {
        var entries: [HistoryEntry]
    }

    init() {
        url = Paths.historyFile
        if let file = StoreJSON.load(File.self, from: url) {
            entries = file.entries.sorted { $0.date > $1.date }
        } else {
            save()
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        let max = limit()
        if max > 0, entries.count > max {
            entries.removeLast(entries.count - max)
        }
        save()
    }

    func delete(ids: Set<UUID>) {
        let before = entries.count
        entries.removeAll { ids.contains($0.id) }
        if entries.count != before { save() }
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        StoreJSON.save(File(entries: entries), to: url)
    }
}
