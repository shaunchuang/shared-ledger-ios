import Foundation

/// A rebuildable, single-book projection. No member names, notes, or account data
/// leave the app's stores. Shared with the extension without importing Core Data.
struct LedgerWidgetSnapshot: Codable, Equatable {
    static let version = 1
    let schemaVersion: Int
    let bookID: UUID
    let groupName: String
    let bookName: String
    let currencyCode: String
    let updatedAt: Date
    let month: DateInterval
    let timeZoneIdentifier: String
    let days: [Day]

    struct Day: Codable, Equatable {
        let date: Date
        var income: Decimal = 0
        var expense: Decimal = 0
        var entryCount: Int = 0
    }

    struct Summary: Equatable {
        let income: Decimal
        let expense: Decimal
        let todayCount: Int
    }

    func summary(at date: Date, calendar: Calendar = .current) -> Summary? {
        // Never relabel last month's money as this month's, or show yesterday's
        // count after midnight. A time-zone change needs a fresh app projection.
        guard schemaVersion == Self.version,
              calendar.timeZone.identifier == timeZoneIdentifier,
              date >= month.start, date < month.end else { return nil }
        return Summary(
            income: days.reduce(0) { $0 + $1.income },
            expense: days.reduce(0) { $0 + $1.expense },
            todayCount: days.filter { calendar.isDate($0.date, inSameDayAs: date) }
                .reduce(0) { $0 + $1.entryCount }
        )
    }

    /// Preload midnight transitions so a delayed WidgetKit reload cannot keep a
    /// previous day's count on screen. The month-end entry requests an app refresh.
    func timelineDates(from date: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [date]
        var next = calendar.startOfDay(for: date)
        for _ in 0..<32 {
            guard let following = calendar.date(byAdding: .day, value: 1, to: next),
                  following > next else { break }
            dates.append(following)
            if following >= month.end { break }
            next = following
        }
        return dates
    }
}
