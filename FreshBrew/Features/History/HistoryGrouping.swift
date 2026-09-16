import Foundation

struct HistoryDay: Identifiable, Equatable {
    let date: Date
    let entries: [UpdateHistoryEntry]

    var id: Date { date }
}

enum HistoryGrouping {
    private static let currentDateStyle = Date.FormatStyle(
        date: .long,
        time: .omitted,
        locale: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )
    private static let currentTimeStyle = Date.FormatStyle(
        date: .omitted,
        time: .shortened,
        locale: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )

    static func days(
        from entries: [UpdateHistoryEntry],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [HistoryDay] {
        let grouped = Dictionary(grouping: entries) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return grouped.keys.sorted(by: >).map { date in
            HistoryDay(
                date: date,
                entries: (grouped[date] ?? []).sorted { $0.timestamp > $1.timestamp }
            )
        }
    }

    static func dateTitle(for date: Date) -> String {
        date.formatted(currentDateStyle)
    }

    static func dateTitle(
        for date: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .long,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }

    static func timeTitle(for date: Date) -> String {
        date.formatted(currentTimeStyle)
    }

    static func timeTitle(
        for date: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        ))
    }
}
