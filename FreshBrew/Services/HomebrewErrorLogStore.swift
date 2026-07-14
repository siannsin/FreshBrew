import Foundation

actor HomebrewErrorLogStore {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = HomebrewErrorLogStore.defaultFileURL()) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    nonisolated static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("FreshBrew", isDirectory: true)
            .appendingPathComponent("homebrew-errors.json")
    }

    func record(
        operation: String,
        output: String,
        timestamp: Date = Date()
    ) throws {
        var currentEntries = try entries(referenceDate: timestamp)
        currentEntries.insert(
            HomebrewErrorLogEntry(
                operation: operation,
                output: output,
                timestamp: timestamp
            ),
            at: 0
        )
        try save(currentEntries)
    }

    func entries(referenceDate: Date = Date()) throws -> [HomebrewErrorLogEntry] {
        let entries = try load()
        let cutoff = referenceDate.addingTimeInterval(-Self.retentionInterval)
        let retained = entries.filter { $0.timestamp >= cutoff }
        if retained != entries {
            try save(retained)
        }
        return retained
    }

    private func load() throws -> [HomebrewErrorLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([HomebrewErrorLogEntry].self, from: data)
    }

    private func save(_ entries: [HomebrewErrorLogEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
