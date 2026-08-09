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

    func testPackageHomepageStorePersistsURLsByPackageIdentity() throws {
        let defaults = InMemoryPreferencesStore()
        let firstStore = PackageHomepageStore(defaults: defaults)
        let homepageURL = try XCTUnwrap(URL(string: "https://chatgpt.com/"))

        firstStore.save(["cask:chatgpt": homepageURL])

        let secondStore = PackageHomepageStore(defaults: defaults)
        XCTAssertEqual(secondStore.url(for: "cask:chatgpt"), homepageURL)
        XCTAssertNil(secondStore.url(for: "formula:chatgpt"))
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
