import Foundation

struct HistoryDay: Identifiable, Equatable {
    let date: Date
    let entries: [UpdateHistoryEntry]

    var id: Date { date }
}

enum HistoryGrouping {
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

    static func dateTitle(
        for date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func timeTitle(
        for date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
