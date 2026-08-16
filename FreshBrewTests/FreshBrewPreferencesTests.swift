import Foundation
import XCTest
@testable import FreshBrew

final class FreshBrewPreferencesTests: XCTestCase {
    private var defaults: InMemoryPreferencesStore!

    override func setUp() {
        defaults = InMemoryPreferencesStore()
    }

    override func tearDown() {
        defaults = nil
    }

    func testFreshDomainDefaultsToGreedyOffAndAfterUnlock() {
        let preferences = FreshBrewPreferences(defaults: defaults)

        XCTAssertFalse(preferences.greedyModeEnabled)
        XCTAssertEqual(preferences.automaticCheckMode, .afterUnlock)
        XCTAssertEqual(preferences.periodicCheckInterval, 14_400)
        XCTAssertFalse(preferences.autoCleanupEnabled)
        XCTAssertFalse(preferences.launchAtLoginEnabled)
        XCTAssertTrue(preferences.appUpdateChecksEnabled)
        XCTAssertTrue(preferences.rememberedSkippedPackageIDs.isEmpty)
        XCTAssertNil(preferences.lastHomebrewCheckDate)
        XCTAssertNil(preferences.lastSuccessfulAppUpdateCheckDate)
        XCTAssertNil(preferences.lastNotifiedAppVersion)
    }

    func testPreferencesPersistIndependentFreshBrewValues() {
        let first = FreshBrewPreferences(defaults: defaults)
        first.greedyModeEnabled = true
        first.automaticCheckMode = .periodic
        first.periodicCheckInterval = 28_800
        first.rememberedSkippedPackageIDs = ["cask:firefox"]
        first.appUpdateChecksEnabled = false
        let date = Date(timeIntervalSince1970: 1234)
        first.lastHomebrewCheckDate = date
        first.lastSuccessfulAppUpdateCheckDate = date.addingTimeInterval(10)
        first.lastNotifiedAppVersion = "0.2.0"

        let second = FreshBrewPreferences(defaults: defaults)
        XCTAssertTrue(second.greedyModeEnabled)
        XCTAssertEqual(second.automaticCheckMode, .periodic)
        XCTAssertEqual(second.periodicCheckInterval, 28_800)
        XCTAssertEqual(second.rememberedSkippedPackageIDs, ["cask:firefox"])
        XCTAssertFalse(second.appUpdateChecksEnabled)
        XCTAssertEqual(second.lastHomebrewCheckDate, date)
        XCTAssertEqual(
            second.lastSuccessfulAppUpdateCheckDate,
            date.addingTimeInterval(10)
        )
        XCTAssertEqual(second.lastNotifiedAppVersion, "0.2.0")
    }
}
