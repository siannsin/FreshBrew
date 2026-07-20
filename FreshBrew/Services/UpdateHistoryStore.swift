import Foundation

final class UpdateHistoryStore: @unchecked Sendable {
    private static let key = "updateHistory"

    private let defaults: any PreferencesStoring
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: any PreferencesStoring = UserDefaults.standard) {
        self.defaults = defaults
    }

    func load() -> [UpdateHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? decoder.decode([UpdateHistoryEntry].self, from: data)) ?? []
    }

    func append(packages: [UpdatedPackage], timestamp: Date) -> [UpdateHistoryEntry] {
        guard !packages.isEmpty else { return load() }

        lock.lock()
        defer { lock.unlock() }
        let existing: [UpdateHistoryEntry]
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? decoder.decode([UpdateHistoryEntry].self, from: data) {
            existing = decoded
        } else {
            existing = []
        }

        let updated = [UpdateHistoryEntry(packages: packages, timestamp: timestamp)] + existing
        if let data = try? encoder.encode(updated) {
            defaults.set(data, forKey: Self.key)
        }
        return updated
    }
}
