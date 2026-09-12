import Foundation
import XCTest
@testable import FreshBrew

final class PersistenceStoreTests: XCTestCase {
    func testHistoryStorePersistsNewestEntryFirst() {
        let defaults = InMemoryPreferencesStore()
        let store = UpdateHistoryStore(defaults: defaults)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        _ = store.append(packages: [updatedPackage(named: "first")], timestamp: firstDate)
        _ = store.append(packages: [updatedPackage(named: "second")], timestamp: secondDate)

        let entries = store.load()
        XCTAssertEqual(entries.map(\.timestamp), [secondDate, firstDate])
        XCTAssertEqual(entries.first?.packages.map(\.name), ["second"])
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
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001","packages":[{"name":"wget","previousVersion":"1.0","installedVersion":"2.0","kind":"formula"}],"timestamp":100}]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "updateHistory")

        let entries = UpdateHistoryStore(defaults: defaults).load()

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
}
