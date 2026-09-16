import CoreData
import Foundation

@MainActor
struct LedgerWidgetSnapshotService {
    let persistence: PersistenceController

    func snapshot(bookID: UUID, now: Date = Date(), calendar: Calendar = .current) throws -> LedgerWidgetSnapshot? {
        let context = persistence.container.viewContext
        let request = NSFetchRequest<LedgerBook>(entityName: "LedgerBook")
        request.predicate = NSPredicate(format: "id == %@ AND archivedAt == nil", bookID as CVarArg)
        request.fetchLimit = 1
        guard let book = try context.fetch(request).first,
              let group = book.group,
              let month = calendar.dateInterval(of: .month, for: now) else { return nil }

        let voidedIDs = EntryRepository(persistence: persistence).voidedEntryIDs(in: group)
        let entries = NSFetchRequest<LedgerEntry>(entityName: "LedgerEntry")
        entries.predicate = NSPredicate(
            format: "book == %@ AND group == %@ AND date >= %@ AND date < %@ AND kind IN %@",
            book, group, month.start as NSDate, month.end as NSDate,
            [EntryKind.expense.rawValue, EntryKind.income.rawValue]
        )
        var days: [Date: LedgerWidgetSnapshot.Day] = [:]
        for entry in try context.fetch(entries) {
            guard let id = entry.id, !voidedIDs.contains(id), let date = entry.date,
                  let amount = entry.amount as Decimal?, amount >= 0 else { continue }
            let day = calendar.startOfDay(for: date)
            var value = days[day] ?? LedgerWidgetSnapshot.Day(date: day)
            if entry.kind == EntryKind.income.rawValue { value.income += amount }
            else { value.expense += amount }
            value.entryCount += 1
            days[day] = value
        }
        return LedgerWidgetSnapshot(
            schemaVersion: LedgerWidgetSnapshot.version,
            bookID: bookID,
            groupName: group.name ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string(),
            bookName: book.name ?? LedgerStringKey.commonPlaceholderUnnamedBook.string(),
            currencyCode: LedgerCurrency.normalizedCode(group.currencyCode),
            updatedAt: now, month: month, timeZoneIdentifier: calendar.timeZone.identifier,
            days: days.values.sorted { $0.date < $1.date }
        )
    }
}
