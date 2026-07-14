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
}
