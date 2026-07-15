import Foundation
import XCTest
@testable import FreshBrew

final class FreshBrewPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "net.siann.freshbrew.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testFreshDomainDefaultsToGreedyOffAndAfterUnlock() {
        let preferences = FreshBrewPreferences(defaults: defaults)

        XCTAssertFalse(preferences.greedyModeEnabled)
        XCTAssertEqual(preferences.automaticCheckMode, .afterUnlock)
        XCTAssertEqual(preferences.periodicCheckInterval, 14_400)
        XCTAssertFalse(preferences.autoCleanupEnabled)
        XCTAssertFalse(preferences.launchAtLoginEnabled)
        XCTAssertTrue(preferences.rememberedSkippedPackageIDs.isEmpty)
        XCTAssertNil(preferences.lastHomebrewCheckDate)
    }

    func testPreferencesPersistIndependentFreshBrewValues() {
        let first = FreshBrewPreferences(defaults: defaults)
        first.greedyModeEnabled = true
        first.automaticCheckMode = .periodic
        first.periodicCheckInterval = 28_800
        first.rememberedSkippedPackageIDs = ["cask:firefox"]
        let date = Date(timeIntervalSince1970: 1234)
        first.lastHomebrewCheckDate = date

        let second = FreshBrewPreferences(defaults: defaults)
        XCTAssertTrue(second.greedyModeEnabled)
        XCTAssertEqual(second.automaticCheckMode, .periodic)
        XCTAssertEqual(second.periodicCheckInterval, 28_800)
        XCTAssertEqual(second.rememberedSkippedPackageIDs, ["cask:firefox"])
        XCTAssertEqual(second.lastHomebrewCheckDate, date)
    }
}
