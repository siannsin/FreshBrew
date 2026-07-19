import Foundation
import XCTest
@testable import FreshBrew

final class HistoryGroupingTests: XCTestCase {
    func testDateAndTimeTitlesFollowLocale() {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 2,
            hour: 17,
            minute: 25
        ))!

        XCTAssertEqual(
            HistoryGrouping.dateTitle(
                for: date,
                locale: Locale(identifier: "en_AU"),
                calendar: calendar,
                timeZone: timeZone
            ),
            "2 July 2026"
        )
        let timeTitle = HistoryGrouping.timeTitle(
            for: date,
            locale: Locale(identifier: "en_AU"),
            calendar: calendar,
            timeZone: timeZone
        )
        XCTAssertTrue(timeTitle.contains("5:25"))
        XCTAssertTrue(timeTitle.lowercased().contains("pm"))
    }

    func testDaysAreNewestFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let older = UpdateHistoryEntry(
            packages: [],
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let newer = UpdateHistoryEntry(
            packages: [],
            timestamp: Date(timeIntervalSince1970: 100_000)
        )

        let days = HistoryGrouping.days(from: [older, newer], calendar: calendar)

        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first?.entries.first?.id, newer.id)
    }

    func testCaskVersionDisplayUsesPrimaryCommaSeparatedVersion() {
        let package = UpdatedPackage(
            name: "claude",
            previousVersion: "1.214591.1,85cb5c02268829ab7605f76dfa13a4217159ca9f",
            installedVersion: "1.22209.0,77c938bac27689d6df971289c10759e512785c73",
            kind: .cask
        )

        XCTAssertEqual(
            HomebrewVersionDisplay.compactTransition(for: package),
            "1.214591.1 → 1.22209.0"
        )
        XCTAssertEqual(
            HomebrewVersionDisplay.fullTransition(for: package),
            "1.214591.1,85cb5c02268829ab7605f76dfa13a4217159ca9f → "
                + "1.22209.0,77c938bac27689d6df971289c10759e512785c73"
        )
    }

    func testAvailableCaskVersionDisplayUsesPrimaryCommaSeparatedVersion() {
        let package = HomebrewPackage(
            name: "claude",
            installedVersion: "1.22209.0,77c938bac27689c10759e512785c73",
            availableVersion: "1.22209.3,babe11577dfefe3e209c06bd674628d862f0dbae",
            kind: .cask
        )

        XCTAssertEqual(
            HomebrewVersionDisplay.compactTransition(for: package),
            "1.22209.0 → 1.22209.3"
        )
    }

    func testAvailableCaskSecondaryVersionChangeUsesCompactTransition() {
        let package = HomebrewPackage(
            name: "chatgpt",
            installedVersion: "2.2,old-revision",
            availableVersion: "2.2,new-revision",
            kind: .cask
        )

        XCTAssertEqual(
            HomebrewVersionDisplay.compactTransition(for: package),
            "2.2 → 2.2"
        )
    }

    func testFormulaVersionDisplayPreservesCommas() {
        XCTAssertEqual(
            HomebrewVersionDisplay.compact("1.2,build", kind: .formula),
            "1.2,build"
        )
    }

    func testCaskVersionWithoutCommaIsUnchanged() {
        XCTAssertEqual(
            HomebrewVersionDisplay.compact("1.2.3", kind: .cask),
            "1.2.3"
        )
    }
}
