import Foundation
import XCTest
@testable import FreshBrew

final class PersistenceStoreTests: XCTestCase {
    func testHistoryStorePersistsNewestEntryFirst() {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let fileURL = directory.appendingPathComponent("update-history.json")
        let store = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { secondDate }
        )

        _ = store.append(packages: [updatedPackage(named: "first")], timestamp: firstDate)
        _ = store.append(packages: [updatedPackage(named: "second")], timestamp: secondDate)

        let entries = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { secondDate }
        ).load()
        XCTAssertEqual(entries.map(\.timestamp), [secondDate, firstDate])
        XCTAssertEqual(entries.first?.packages.map(\.name), ["second"])
    }

    func testHistoryStoreMigratesLegacyDefaultsAndRemovesThemAfterVerification() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = historyDate(year: 2026, month: 9, day: 16)
        let expired = historyEntry(
            named: "expired",
            timestamp: historyDate(year: 2026, month: 3, day: 15)
        )
        let boundary = historyEntry(
            named: "boundary",
            timestamp: historyDate(year: 2026, month: 3, day: 16)
        )
        let newest = historyEntry(named: "newest", timestamp: referenceDate)
        defaults.set(
            try JSONEncoder().encode([expired, boundary, newest]),
            forKey: "updateHistory"
        )

        let entries = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { referenceDate },
            calendar: historyCalendar()
        ).load()

        XCTAssertEqual(entries.map(\.id), [newest.id, boundary.id])
        XCTAssertNil(defaults.data(forKey: "updateHistory"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UpdateHistoryEntry].self,
                from: Data(contentsOf: fileURL)
            ),
            entries
        )
    }

    func testHistoryStorePrunesExpiredFileEntriesOnLoad() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = historyDate(year: 2026, month: 9, day: 16)
        let expired = historyEntry(
            named: "expired",
            timestamp: historyDate(year: 2026, month: 3, day: 15)
        )
        let retained = historyEntry(
            named: "retained",
            timestamp: historyDate(year: 2026, month: 9, day: 1)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([expired, retained]).write(to: fileURL)
        let store = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { referenceDate },
            calendar: historyCalendar()
        )

        XCTAssertEqual(store.load().map(\.id), [retained.id])
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UpdateHistoryEntry].self,
                from: Data(contentsOf: fileURL)
            ).map(\.id),
            [retained.id]
        )
    }

    func testHistoryStoreKeepsNewestEntryAfterLongInactivePeriod() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = historyEntry(
            named: "older",
            timestamp: historyDate(year: 2024, month: 1, day: 1)
        )
        let newest = historyEntry(
            named: "newest",
            timestamp: historyDate(year: 2024, month: 2, day: 1)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([older, newest]).write(to: fileURL)
        let referenceDate = historyDate(year: 2026, month: 9, day: 16)

        let entries = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { referenceDate },
            calendar: historyCalendar()
        ).load()

        XCTAssertEqual(entries.map(\.id), [newest.id])
    }

    func testHistoryStoreTreatsExistingJSONAsAuthoritativeAndFinishesMigrationCleanup() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = historyDate(year: 2026, month: 9, day: 16)
        let fileEntry = historyEntry(named: "file", timestamp: referenceDate)
        let legacyEntry = historyEntry(named: "legacy", timestamp: referenceDate)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([fileEntry]).write(to: fileURL)
        let legacyData = try JSONEncoder().encode([legacyEntry])
        defaults.set(legacyData, forKey: "updateHistory")

        let entries = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { referenceDate },
            calendar: historyCalendar()
        ).load()

        XCTAssertEqual(entries.map(\.id), [fileEntry.id])
        XCTAssertNil(defaults.data(forKey: "updateHistory"))
    }

    func testHistoryStorePrunesExpiredEntriesWhenAppending() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceDate = historyDate(year: 2026, month: 9, day: 16)
        let expired = historyEntry(
            named: "expired",
            timestamp: historyDate(year: 2026, month: 3, day: 15)
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([expired]).write(to: fileURL)
        let store = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { referenceDate },
            calendar: historyCalendar()
        )

        let entries = store.append(
            packages: [updatedPackage(named: "new")],
            timestamp: referenceDate
        )

        XCTAssertEqual(entries.flatMap(\.packages).map(\.name), ["new"])
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UpdateHistoryEntry].self,
                from: Data(contentsOf: fileURL)
            ),
            entries
        )
    }

    func testHistoryStorePreservesMalformedJSONAndPersistsNewHistory() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        let corruptURL = UpdateHistoryStore.corruptFileURL(for: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let malformedData = Data("{malformed history".utf8)
        try malformedData.write(to: fileURL)
        let timestamp = historyDate(year: 2026, month: 9, day: 16)
        let store = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { timestamp },
            calendar: historyCalendar()
        )

        let entries = store.append(
            packages: [updatedPackage(named: "new")],
            timestamp: timestamp
        )

        XCTAssertEqual(entries.first?.packages.first?.name, "new")
        XCTAssertEqual(try Data(contentsOf: corruptURL), malformedData)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UpdateHistoryEntry].self,
                from: Data(contentsOf: fileURL)
            ),
            entries
        )
    }

    func testHistoryStoreDiscardsMalformedLegacyDataAndPersistsNewHistory() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformedData = Data("{malformed legacy history".utf8)
        defaults.set(malformedData, forKey: "updateHistory")
        let timestamp = historyDate(year: 2026, month: 9, day: 16)
        let store = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { timestamp },
            calendar: historyCalendar()
        )

        _ = store.append(
            packages: [updatedPackage(named: "new")],
            timestamp: timestamp
        )

        XCTAssertNil(defaults.data(forKey: "updateHistory"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UpdateHistoryEntry].self,
                from: Data(contentsOf: fileURL)
            ).first?.packages.first?.name,
            "new"
        )
    }

    func testHistoryStoreKeepsLegacyDataWhenMigrationWriteFails() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        let parentFileURL = directory.appendingPathComponent("not-a-directory")
        let fileURL = parentFileURL.appendingPathComponent("update-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: parentFileURL.path, contents: Data()))
        let timestamp = historyDate(year: 2026, month: 9, day: 16)
        let legacyEntry = historyEntry(named: "legacy", timestamp: timestamp)
        let legacyData = try JSONEncoder().encode([legacyEntry])
        defaults.set(legacyData, forKey: "updateHistory")

        let entries = UpdateHistoryStore(
            defaults: defaults,
            fileURL: fileURL,
            now: { timestamp },
            calendar: historyCalendar()
        ).load()

        XCTAssertEqual(entries.map(\.id), [legacyEntry.id])
        XCTAssertEqual(defaults.data(forKey: "updateHistory"), legacyData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parentFileURL.path))
    }

    func testDefaultHistoryStoreUsesFreshBrewApplicationSupportDirectory() {
        XCTAssertTrue(
            UpdateHistoryStore.defaultFileURL().path.hasSuffix(
                "Application Support/\(AppIdentity.bundleName)/update-history.json"
            )
        )
    }

    func testErrorLogRetainsOnlySevenDays() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("homebrew-errors.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomebrewErrorLogStore(fileURL: fileURL)
        let referenceDate = Date(timeIntervalSince1970: 1_000_000)

        try await store.record(
            operation: "old operation",
            output: "old output",
            timestamp: referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        try await store.record(
            operation: "recent operation",
            output: "recent output",
            timestamp: referenceDate
        )

        let entries = try await store.entries(referenceDate: referenceDate)
        XCTAssertEqual(entries.map(\.operation), ["recent operation"])
        let encodedLog = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(encodedLog.contains("recent output"))
        XCTAssertFalse(encodedLog.contains("old output"))
    }

    func testErrorLogPrunesExpiredEntriesWithoutRecordingAnotherFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("homebrew-errors.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomebrewErrorLogStore(fileURL: fileURL)
        let timestamp = Date(timeIntervalSince1970: 1_000_000)

        try await store.record(
            operation: "expired operation",
            output: "expired output",
            timestamp: timestamp
        )
        try await store.pruneExpiredEntries(
            referenceDate: timestamp.addingTimeInterval(8 * 24 * 60 * 60)
        )

        let entries = try await store.entries(
            referenceDate: timestamp.addingTimeInterval(8 * 24 * 60 * 60)
        )
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(
            try JSONDecoder().decode(
                [HomebrewErrorLogEntry].self,
                from: Data(contentsOf: fileURL)
            ).isEmpty
        )
    }

    func testErrorLogRecoversFromMalformedJSONAndKeepsOneCorruptCopy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("homebrew-errors.json")
        let corruptURL = HomebrewErrorLogStore.corruptFileURL(for: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstMalformedData = Data("{first malformed log".utf8)
        try firstMalformedData.write(to: fileURL)
        let store = HomebrewErrorLogStore(fileURL: fileURL)

        try await store.record(operation: "first new failure", output: "first output")
        let firstEntries = try await store.entries()
        XCTAssertEqual(try Data(contentsOf: corruptURL), firstMalformedData)
        XCTAssertEqual(firstEntries.map(\.operation), ["first new failure"])

        let secondMalformedData = Data("{second malformed log".utf8)
        try secondMalformedData.write(to: fileURL)
        try await store.record(operation: "second new failure", output: "second output")
        let secondEntries = try await store.entries()

        XCTAssertEqual(try Data(contentsOf: corruptURL), secondMalformedData)
        XCTAssertEqual(secondEntries.map(\.operation), ["second new failure"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["homebrew-errors.corrupt.json", "homebrew-errors.json"]
        )
    }

    func testErrorLogBoundsCorruptCopyEntriesAndOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("homebrew-errors.json")
        let corruptURL = HomebrewErrorLogStore.corruptFileURL(for: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            repeating: 0x78,
            count: HomebrewErrorLogStore.maximumCorruptCopyBytes + 1_024
        ).write(to: fileURL)
        let store = HomebrewErrorLogStore(fileURL: fileURL)

        _ = try await store.entries()
        XCTAssertEqual(
            try Data(contentsOf: corruptURL).count,
            HomebrewErrorLogStore.maximumCorruptCopyBytes
        )

        for index in 0..<(HomebrewErrorLogStore.maximumEntryCount + 5) {
            try await store.record(
                operation: "operation \(index)",
                output: "output \(index)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let oversizedOutput = String(
            repeating: "é",
            count: HomebrewErrorLogStore.maximumOutputBytes
        )
        try await store.record(
            operation: "newest operation",
            output: oversizedOutput,
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let entries = try await store.entries(referenceDate: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(entries.count, HomebrewErrorLogStore.maximumEntryCount)
        XCTAssertEqual(entries.first?.operation, "newest operation")
        XCTAssertLessThanOrEqual(
            entries.first?.output.utf8.count ?? .max,
            HomebrewErrorLogStore.maximumOutputBytes
        )
        XCTAssertTrue(entries.first?.output.hasSuffix("… [truncated]") == true)
    }

    func testErrorLogCreatesAndCorrectsOwnerOnlyFilePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("homebrew-errors.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomebrewErrorLogStore(fileURL: fileURL)

        try await store.record(operation: "first", output: "output")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )
        try await store.record(operation: "second", output: "output")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    }

    func testErrorLogDoesNotTreatDirectoryFailureAsCorruptJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parentFileURL = directory.appendingPathComponent("not-a-directory")
        let fileURL = parentFileURL.appendingPathComponent("homebrew-errors.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: parentFileURL.path, contents: Data()))
        let store = HomebrewErrorLogStore(fileURL: fileURL)

        do {
            try await store.record(operation: "failure", output: "output")
            XCTFail("Expected directory creation to fail")
        } catch {
            XCTAssertFalse(error is DecodingError)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: parentFileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: HomebrewErrorLogStore.corruptFileURL(for: fileURL).path
            )
        )
    }

    func testErrorLogPropagatesWriteFailureWithoutReplacingItAsCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("homebrew-errors.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        let store = HomebrewErrorLogStore(fileURL: fileURL)

        do {
            try await store.record(operation: "failure", output: "output")
            XCTFail("Expected writing the diagnostic log to fail")
        } catch {
            XCTAssertFalse(error is DecodingError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDefaultErrorLogUsesFreshBrewApplicationSupportDirectory() {
        XCTAssertTrue(
            HomebrewErrorLogStore.defaultFileURL().path.hasSuffix(
                "Application Support/FreshBrew/homebrew-errors.json"
            )
        )
    }

    func testPackageHomepageStorePersistsURLsByPackageIdentity() throws {
        let defaults = InMemoryPreferencesStore()
        let firstStore = PackageHomepageStore(defaults: defaults)
        let homepageURL = try XCTUnwrap(URL(string: "https://chatgpt.com/"))

        firstStore.save(["cask:chatgpt": homepageURL])

        let secondStore = PackageHomepageStore(defaults: defaults)
        XCTAssertEqual(secondStore.url(for: "cask:chatgpt"), homepageURL)
        XCTAssertNil(secondStore.url(for: "formula:chatgpt"))
    }

    func testPackageHomepageStoreMigratesLegacyIdentityWithoutOverwritingCanonicalURL() throws {
        let defaults = InMemoryPreferencesStore()
        let store = PackageHomepageStore(defaults: defaults)
        let legacyURL = try XCTUnwrap(URL(string: "https://example.com/legacy"))
        let canonicalURL = try XCTUnwrap(URL(string: "https://example.com/canonical"))
        store.save([
            "formula:bun": legacyURL,
            "formula:oven-sh/bun/bun": canonicalURL
        ])

        store.migrateURL(from: "formula:bun", to: "formula:oven-sh/bun/bun")

        XCTAssertNil(store.url(for: "formula:bun"))
        XCTAssertEqual(store.url(for: "formula:oven-sh/bun/bun"), canonicalURL)
    }

    func testHistoryStoreDecodesLegacyPackagesWithoutHomepage() throws {
        let defaults = InMemoryPreferencesStore()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001","packages":[{"name":"wget","previousVersion":"1.0","installedVersion":"2.0","kind":"formula"}],"timestamp":100}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "updateHistory")

        let entries = UpdateHistoryStore(
            defaults: defaults,
            fileURL: directory.appendingPathComponent("update-history.json"),
            now: { Date(timeIntervalSince1970: 100) }
        ).load()

        XCTAssertEqual(entries.first?.packages.first?.name, "wget")
        XCTAssertNil(entries.first?.packages.first?.homepageURL)
    }

    private func updatedPackage(named name: String) -> UpdatedPackage {
        UpdatedPackage(
            name: name,
            previousVersion: "1.0",
            installedVersion: "2.0",
            kind: .formula
        )
    }

    private func historyEntry(named name: String, timestamp: Date) -> UpdateHistoryEntry {
        UpdateHistoryEntry(packages: [updatedPackage(named: name)], timestamp: timestamp)
    }

    private func historyCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func historyDate(year: Int, month: Int, day: Int) -> Date {
        historyCalendar().date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
