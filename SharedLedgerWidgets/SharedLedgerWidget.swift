import SwiftUI
import WidgetKit

private struct LedgerWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerWidgetSnapshot?
}

private struct LedgerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LedgerWidgetEntry {
        // Placeholder redaction is supplied by WidgetKit; no sample transactions
        // can leak into the installed widget's real timeline.
        LedgerWidgetEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LedgerWidgetEntry) -> Void) {
        completion(LedgerWidgetEntry(date: Date(), snapshot: LedgerWidgetStore.shared.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LedgerWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = LedgerWidgetStore.shared.load()
        let dates = snapshot?.timelineDates(from: now) ?? [now]
        completion(Timeline(
            entries: dates.map { LedgerWidgetEntry(date: $0, snapshot: snapshot) },
            policy: .after(now.addingTimeInterval(30 * 60))
        ))
    }
}

private struct LedgerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LedgerWidgetEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                if let summary = snapshot.summary(at: entry.date) {
                    summaryView(snapshot, summary: summary)
                } else {
                    emptyView(title: .widgetRefreshTitle, message: .widgetRefreshMessage)
                        .widgetURL(LedgerWidgetRoute.newEntry(bookID: snapshot.bookID, kind: .expense).url)
                }
            } else {
                emptyView(title: .widgetSetupTitle, message: .widgetSetupMessage)
                    .widgetURL(LedgerWidgetRoute.settings.url)
            }
        }
        .containerBackground(LedgerTheme.surface, for: .widget)
    }

    private func summaryView(_ snapshot: LedgerWidgetSnapshot, summary: LedgerWidgetSnapshot.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(LedgerTheme.primary)
                    .accessibilityHidden(true)
                Text(verbatim: "\(snapshot.groupName) · \(snapshot.bookName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(alignment: .top, spacing: 16) {
                metric(.widgetMonthExpense, amount: summary.expense, currency: snapshot.currencyCode)
                if family == .systemMedium {
                    metric(.widgetMonthIncome, amount: summary.income, currency: snapshot.currencyCode)
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: LedgerStringKey.widgetTodayCount.string(arguments: [Int64(summary.todayCount)]))
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if family == .systemMedium {
                    Spacer(minLength: 0)
                    updatedAt(snapshot)
                }
            }
            Spacer(minLength: 0)
            if family == .systemMedium {
                HStack(spacing: 10) {
                    action(.widgetAddExpense, kind: .expense, bookID: snapshot.bookID)
                    action(.widgetAddIncome, kind: .income, bookID: snapshot.bookID)
                }
            } else {
                Label(.widgetAddExpense, systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LedgerTheme.primary)
            }
            if family == .systemSmall { updatedAt(snapshot) }
        }
        .privacySensitive()
        .widgetURL(LedgerWidgetRoute.newEntry(bookID: snapshot.bookID, kind: .expense).url)
    }

    private func updatedAt(_ snapshot: LedgerWidgetSnapshot) -> some View {
        Text(verbatim: LedgerStringKey.widgetUpdatedAt.string(
            arguments: [LedgerFormatters.timestamp(snapshot.updatedAt)]
        ))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func metric(_ title: LedgerStringKey, amount: Decimal, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: LedgerCurrency.format(amount, currencyCode: currency))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func action(_ title: LedgerStringKey, kind: EntryKind, bookID: UUID) -> some View {
        Link(destination: LedgerWidgetRoute.newEntry(bookID: bookID, kind: kind).url) {
            Label(title, systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(LedgerTheme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(LedgerTheme.primary)
        }
    }

    private func emptyView(title: LedgerStringKey, message: LedgerStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(LedgerTheme.primary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@main
struct SharedLedgerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LedgerWidgetStore.widgetKind, provider: LedgerWidgetProvider()) { entry in
            LedgerWidgetView(entry: entry)
        }
        .configurationDisplayName(LedgerStringKey.widgetTitle.string())
        .description(LedgerStringKey.widgetDescription.string())
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
