import SwiftUI

extension LedgerSyncState {
    var systemImage: String {
        switch self {
        case .signedOut: return "icloud.slash"
        case .restricted: return "lock.icloud"
        case .undetermined: return "icloud"
        case .offline: return "wifi.slash"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .upToDate: return "checkmark.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .upToDate: return LedgerTheme.primary
        case .syncing: return .blue
        case .offline, .undetermined: return LedgerTheme.amber
        case .signedOut, .restricted, .failed: return LedgerTheme.coral
        }
    }
}

/// iCloud 同步狀態的細節畫面。
struct SyncStatusView: View {
    @ObservedObject var monitor: SyncStatusMonitor

    @Environment(\.managedObjectContext) private var context

    /// 掃描要讀每一筆收支交易的付款與分攤，所以只在畫面出現與資料真的變動時跑一次，
    /// 不放進 `body`。
    @State private var conflicts: [EntryConflict] = []
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LedgerIconBadge(
                        systemImage: monitor.state.systemImage,
                        tint: monitor.state.tint
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.state.title)
                            .font(.headline)
                        if case .syncing = monitor.state {
                            Text(.syncViewInProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if case .syncing = monitor.state {
                        ProgressView()
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                Text(monitor.state.detail(lastSuccessfulSync: monitor.lastSuccessfulSync))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if monitor.state.suggestsRetry {
                Section {
                    Button {
                        monitor.refresh()
                    } label: {
                        Label(.syncViewRecheck, systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text(.syncViewRecheckFooter)
                }
            }

            if !conflicts.isEmpty {
                conflictSection
            }

            Section {
                Label(.syncViewLocalDataTitle, systemImage: "internaldrive")
                    .font(.subheadline)
            } footer: {
                Text(.syncViewLocalDataFooter)
            }
        }
        .navigationTitle(Text(.syncTitle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadConflicts)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: context
            )
        ) { notification in
            guard ContextChangeObserver.touches(notification, .entryDetails, .auditLog) else {
                return
            }
            reloadConflicts()
        }
        .alert(Text(.syncConflictErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: { Text(.commonActionOK) }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    /// 資料衝突。
    ///
    /// 放在同步畫面而不是交易列表，是因為這裡的每一種情況都是同步造成的，而使用者
    /// 會為了「為什麼數字怪怪的」來看同步狀態。列出來的交易可以直接點進交易詳情，
    /// 在那裡用平常的編輯流程修好。
    private var conflictSection: some View {
        Section {
            ForEach(conflicts) { conflict in
                NavigationLink {
                    TransactionDetailView(entry: conflict.entry)
                } label: {
                    ConflictRow(conflict: conflict)
                }
            }

            if canCleanUp {
                Button(action: cleanUpSupersededRows) {
                    Label(.syncConflictActionCleanup, systemImage: "eraser")
                }
            }
        } header: {
            Text(.syncConflictSection)
        } footer: {
            Text(canCleanUp ? .syncConflictCleanupFooter : .syncConflictFooter)
        }
    }

    /// 只有真的有落選明細、而且這台裝置寫得進去的群組才給清除。
    private var canCleanUp: Bool {
        conflicts.contains { $0.isWritable && $0.supersededRowCount > 0 }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func reloadConflicts() {
        conflicts = EntryConflictScanner().conflicts()
    }

    private func cleanUpSupersededRows() {
        let repository = EntryRepository()
        for conflict in conflicts where conflict.isWritable && conflict.supersededRowCount > 0 {
            do {
                try repository.discardSupersededChildren(of: conflict.entry)
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        reloadConflicts()
    }
}

private struct ConflictRow: View {
    let conflict: EntryConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: amount)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(conflict.affectsBalances ? LedgerTheme.coral : .secondary)
            }
            Text(reasonKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// 「帳本 · 日期」。使用者要先認出是哪一筆交易，才看得懂下面那句說明。
    private var title: String {
        let book = conflict.entry.book?.name
            ?? LedgerStringKey.commonPlaceholderUnnamedBook.string()
        guard let date = conflict.entry.date else { return book }
        return LedgerStringKey.reportSourceRowSubtitle.string(
            arguments: [book, LedgerFormatters.longDay(date)]
        )
    }

    private var amount: String {
        LedgerCurrency.formatSigned(
            (conflict.entry.amount as Decimal?) ?? 0,
            kind: conflict.entry.entryKind,
            currencyCode: LedgerCurrency.normalizedCode(conflict.entry.group?.currencyCode)
        )
    }

    private var reasonKey: LedgerStringKey {
        switch conflict.reason {
        case .superseded: return .syncConflictReasonSuperseded
        case .mismatched: return .syncConflictReasonMismatched
        case .missingDetails: return .syncConflictReasonMissingDetails
        }
    }
}

/// 設定頁上的同步狀態列。
struct SyncStatusRow: View {
    @ObservedObject var monitor: SyncStatusMonitor

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconBadge(
                systemImage: monitor.state.systemImage,
                tint: monitor.state.tint
            )
            Text(.syncTitle)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(monitor.state.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            LedgerStringKey.syncRowAccessibilityLabel.string(arguments: [monitor.state.title])
        )
    }
}

#Preview {
    NavigationStack {
        SyncStatusView(
            monitor: SyncStatusMonitor(
                accountStatusProvider: { .available },
                monitorsNetwork: false
            )
        )
    }
    .environment(
        \.managedObjectContext,
        PersistenceController(inMemory: true).container.viewContext
    )
}
