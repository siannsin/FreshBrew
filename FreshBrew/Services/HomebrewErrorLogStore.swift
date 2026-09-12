import Foundation

actor HomebrewErrorLogStore {
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maximumEntryCount = 50
    static let maximumOutputBytes = 64 * 1_024
    static let maximumCorruptCopyBytes = 64 * 1_024

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

    nonisolated static func corruptFileURL(for fileURL: URL) -> URL {
        fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")
    }

    func record(
        operation: String,
        output: String,
        timestamp: Date = Date()
    ) throws {
        var currentEntries = retainedAndBounded(
            try load(),
            referenceDate: timestamp
        )
        currentEntries.insert(
            HomebrewErrorLogEntry(
                operation: operation,
                output: Self.boundedOutput(output),
                timestamp: timestamp
            ),
            at: 0
        )
        try save(retainedAndBounded(currentEntries, referenceDate: timestamp))
    }

    func entries(referenceDate: Date = Date()) throws -> [HomebrewErrorLogEntry] {
        let entries = try load()
        let retained = retainedAndBounded(entries, referenceDate: referenceDate)
        if retained != entries {
            try save(retained)
        }
        return retained
    }

    func pruneExpiredEntries(referenceDate: Date = Date()) throws {
        _ = try entries(referenceDate: referenceDate)
    }

    private func load() throws -> [HomebrewErrorLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try decoder.decode([HomebrewErrorLogEntry].self, from: data)
        } catch is DecodingError {
            try? preserveCorruptCopy(of: data)
            try save([])
            return []
        }
    }

    private func save(_ entries: [HomebrewErrorLogEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func preserveCorruptCopy(of data: Data) throws {
        let copyURL = Self.corruptFileURL(for: fileURL)
        let boundedData = Data(data.prefix(Self.maximumCorruptCopyBytes))
        try boundedData.write(to: copyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: copyURL.path
        )
    }

    private func retainedAndBounded(
        _ entries: [HomebrewErrorLogEntry],
        referenceDate: Date
    ) -> [HomebrewErrorLogEntry] {
        let cutoff = referenceDate.addingTimeInterval(-Self.retentionInterval)
        return entries
            .enumerated()
            .filter { $0.element.timestamp >= cutoff }
            .map { indexedEntry in
                (
                    index: indexedEntry.offset,
                    entry: HomebrewErrorLogEntry(
                        id: indexedEntry.element.id,
                        operation: indexedEntry.element.operation,
                        output: Self.boundedOutput(indexedEntry.element.output),
                        timestamp: indexedEntry.element.timestamp
                    )
                )
            }
            .sorted { first, second in
                if first.entry.timestamp == second.entry.timestamp {
                    return first.index < second.index
                }
                return first.entry.timestamp > second.entry.timestamp
            }
            .prefix(Self.maximumEntryCount)
            .map(\.entry)
    }

    private nonisolated static func boundedOutput(_ output: String) -> String {
        let data = Data(output.utf8)
        guard data.count > maximumOutputBytes else { return output }

        let marker = "\n… [truncated]"
        let contentLimit = maximumOutputBytes - marker.utf8.count
        var prefix = ""
        prefix.reserveCapacity(contentLimit)
        var byteCount = 0
        for character in output {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= contentLimit else { break }
            prefix.append(character)
            byteCount += characterBytes
        }
        return prefix + marker
    }
}
