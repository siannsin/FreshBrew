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

    func testDefaultErrorLogUsesFreshBrewApplicationSupportDirectory() {
        XCTAssertTrue(
            HomebrewErrorLogStore.defaultFileURL().path.hasSuffix(
                "Application Support/FreshBrew/homebrew-errors.json"
            )
        )
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
