import Foundation
import OSLog

final class UpdateHistoryStore: @unchecked Sendable {
    private enum StorageState {
        case ready([UpdateHistoryEntry])
        case readOnly([UpdateHistoryEntry])

        var entries: [UpdateHistoryEntry] {
            switch self {
            case .ready(let entries), .readOnly(let entries): entries
            }
        }

        var canWrite: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private enum StoreError: LocalizedError {
        case migrationVerificationFailed

        var errorDescription: String? {
            switch self {
            case .migrationVerificationFailed:
                "The migrated update history could not be verified."
            }
        }
    }

    private static let legacyKey = "updateHistory"
    private static let logger = Logger(
        subsystem: AppIdentity.bundleIdentifier,
        category: "UpdateHistoryStore"
    )

    private let defaults: any PreferencesStoring
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedState: StorageState?

    init(
        defaults: any PreferencesStoring = UserDefaults.standard,
        fileURL: URL = UpdateHistoryStore.defaultFileURL(),
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
    }

    static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("update-history.json")
    }

    static func corruptFileURL(for fileURL: URL) -> URL {
        fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")
    }

    func load() -> [UpdateHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }

        let referenceDate = now()
        let state = loadState(referenceDate: referenceDate)
        let retained = retainedEntries(state.entries, referenceDate: referenceDate)
        if state.canWrite, retained != state.entries {
            do {
                try save(retained)
            } catch {
                log(error, operation: "prune update history")
            }
        }
        cachedState = state.canWrite ? .ready(retained) : .readOnly(retained)
        return retained
    }

    func append(packages: [UpdatedPackage], timestamp: Date) -> [UpdateHistoryEntry] {
        guard !packages.isEmpty else { return load() }

        lock.lock()
        defer { lock.unlock() }

        let referenceDate = now()
        let state = loadState(referenceDate: referenceDate)
        let updated = retainedEntries(
            [UpdateHistoryEntry(packages: packages, timestamp: timestamp)] + state.entries,
            referenceDate: referenceDate
        )
        if state.canWrite {
            do {
                try save(updated)
            } catch {
                log(error, operation: "save update history")
            }
        }
        cachedState = state.canWrite ? .ready(updated) : .readOnly(updated)
        return updated
    }

    private func loadState(referenceDate: Date) -> StorageState {
        if let cachedState { return cachedState }

        let state: StorageState
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let entries = try decodeFile()
                if defaults.data(forKey: Self.legacyKey) != nil {
                    defaults.removeObject(forKey: Self.legacyKey)
                }
                state = .ready(entries)
            } catch let error as DecodingError {
                log(error, operation: "decode update history")
                do {
                    try preserveMalformedFileAndStartFresh()
                    state = .ready([])
                } catch {
                    log(error, operation: "recover malformed update history")
                    state = .readOnly([])
                }
            } catch {
                log(error, operation: "read update history")
                state = .readOnly([])
            }
        } else {
            state = migrateLegacyHistory(referenceDate: referenceDate)
        }
        cachedState = state
        return state
    }

    private func migrateLegacyHistory(referenceDate: Date) -> StorageState {
        guard let data = defaults.data(forKey: Self.legacyKey) else {
            return .ready([])
        }

        let legacyEntries: [UpdateHistoryEntry]
        do {
            legacyEntries = try decoder.decode([UpdateHistoryEntry].self, from: data)
        } catch {
            log(error, operation: "decode legacy update history")
            do {
                try save([])
                defaults.removeObject(forKey: Self.legacyKey)
                return .ready([])
            } catch {
                log(error, operation: "replace malformed legacy update history")
                return .readOnly([])
            }
        }

        let retained = retainedEntries(legacyEntries, referenceDate: referenceDate)
        do {
            try save(retained)
            guard try decodeFile() == retained else {
                throw StoreError.migrationVerificationFailed
            }
            defaults.removeObject(forKey: Self.legacyKey)
            return .ready(retained)
        } catch {
            log(error, operation: "migrate update history")
            return .readOnly(retained)
        }
    }

    private func decodeFile() throws -> [UpdateHistoryEntry] {
        try decoder.decode(
            [UpdateHistoryEntry].self,
            from: Data(contentsOf: fileURL)
        )
    }

    private func save(_ entries: [UpdateHistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func preserveMalformedFileAndStartFresh() throws {
        let malformedData = try Data(contentsOf: fileURL)
        let corruptURL = Self.corruptFileURL(for: fileURL)
        try malformedData.write(to: corruptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: corruptURL.path
        )
        try save([])
    }

    private func retainedEntries(
        _ entries: [UpdateHistoryEntry],
        referenceDate: Date
    ) -> [UpdateHistoryEntry] {
        let sorted = entries.enumerated().sorted { first, second in
            if first.element.timestamp == second.element.timestamp {
                return first.offset < second.offset
            }
            return first.element.timestamp > second.element.timestamp
        }.map(\.element)
        guard let newest = sorted.first,
              let cutoff = calendar.date(
                byAdding: .month,
                value: -6,
                to: referenceDate
              ) else { return sorted }

        let retained = sorted.filter { $0.timestamp >= cutoff }
        return retained.isEmpty ? [newest] : retained
    }

    private func log(_ error: Error, operation: String) {
        Self.logger.error(
            "Failed to \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }
}
