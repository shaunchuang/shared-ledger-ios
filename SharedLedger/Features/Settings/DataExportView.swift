import CoreData
import SwiftUI
import UIKit

/// 把匯出文件寫成暫存檔，交給系統分享。
///
/// 分享需要真實的檔案 URL，所以文件要先落地。每次匯出都寫進一個新的子目錄：
/// 檔名只帶到日期，同一天重複匯出會互相覆蓋，而使用者可能還在分享上一次的檔案。
enum LedgerExportFileWriter {
    static func write(_ documents: [LedgerExportDocument]) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try documents.map { document in
            let url = directory.appendingPathComponent(document.fileName)
            // CSVWriter 已經在開頭放了 UTF-8 BOM，這裡照原字串寫出即可。
            try document.contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ExportedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct DataExportView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var selectedGroupID: NSManagedObjectID?
    @State private var request = LedgerExportRequest()
    @State private var summary = LedgerExportSummary.empty
    @State private var exportedFiles: ExportedFiles?
    @State private var errorMessage: String?

    private var selectedGroup: LedgerGroup? {
        if let selectedGroupID, let match = groups.first(where: { $0.objectID == selectedGroupID }) {
            return match
        }
        return groups.first
    }

    private var activeBooks: [LedgerBook] {
        guard let selectedGroup else { return [] }
        return BookRepository().books(in: selectedGroup)
    }

    private var currentBook: LedgerBook? {
        guard let selectedGroup else { return nil }
        let storedID = UserDefaults.standard
            .string(forKey: BookSelectionStorage.key(for: selectedGroup))
        return activeBooks.first { $0.id?.uuidString == storedID }
            ?? activeBooks.first(where: \.isDefault)
            ?? activeBooks.first
    }

    private var currencyCode: String {
        LedgerCurrency.normalizedCode(selectedGroup?.currencyCode)
    }

    var body: some View {
        Form {
            if selectedGroup == nil {
                Section {
                    Text(.exportEmpty)
                        .foregroundStyle(.secondary)
                }
            } else {
                groupSection
                scopeSection
                dateSection
                contentSection
                summarySection
            }
        }
        .navigationTitle(Text(.settingsRowExportTitle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadSummary)
        .onChange(of: selectedGroupID) { _, _ in reloadSummary() }
        .onChange(of: request) { _, _ in reloadSummary() }
        .sheet(item: $exportedFiles) { files in
            ShareSheet(items: files.urls)
        }
        .alert(Text(.exportErrorTitle), isPresented: errorBinding) {
            Button(role: .cancel) {} label: {
                Text(.commonActionOK)
            }
        } message: {
            Text(verbatim: errorMessage ?? LedgerStringKey.commonErrorRetryLater.string())
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        // 先解出目前群組再建 binding，選取狀態就永遠有一個真實的 objectID 可用，
        // 不需要為了填滿 binding 生一個不指向任何東西的哨兵值。
        if groups.count > 1, let selectedGroup {
            Section {
                Picker(selection: groupSelection(fallingBackTo: selectedGroup)) {
                    ForEach(Array(groups), id: \.objectID) { group in
                        Text(verbatim: group.name
                            ?? LedgerStringKey.commonPlaceholderUnnamedGroup.string())
                            .tag(group.objectID)
                    }
                } label: {
                    Text(.exportFieldGroup)
                }
            } header: {
                Text(.exportSectionGroup)
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Picker(selection: $request.scope) {
                ForEach(ReportBookScope.allCases) { option in
                    Text(option.displayNameKey).tag(option)
                }
            } label: {
                Text(.exportFieldBookScope)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text(.exportFieldBookScope))

            if request.scope == .selectedBookIDs {
                ForEach(activeBooks, id: \.objectID) { book in
                    if let id = book.id {
                        Button {
                            if request.selectedBookIDs.contains(id) {
                                request.selectedBookIDs.remove(id)
                            } else {
                                request.selectedBookIDs.insert(id)
                            }
                        } label: {
                            HStack {
                                Text(verbatim: book.name
                                    ?? LedgerStringKey.commonPlaceholderUnnamedBook.string())
                                    .foregroundStyle(.primary)
                                Spacer()
                                if request.selectedBookIDs.contains(id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(LedgerTheme.primary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            request.selectedBookIDs.contains(id)
                                ? [.isButton, .isSelected]
                                : .isButton
                        )
                    }
                }
            }
        } header: {
            Text(.exportSectionScope)
        } footer: {
            Text(.exportScopeFooter)
        }
    }

    private var dateSection: some View {
        Section {
            Toggle(isOn: dateRangeBinding) {
                Text(.exportDateToggle)
            }
            if request.startDate != nil || request.endDate != nil {
                DatePicker(
                    selection: dateBinding(for: \.startDate, fallback: defaultStartDate),
                    displayedComponents: .date
                ) {
                    Text(.exportDateStart)
                }
                DatePicker(
                    selection: dateBinding(for: \.endDate, fallback: Date()),
                    displayedComponents: .date
                ) {
                    Text(.exportDateEnd)
                }
            }
        } header: {
            Text(.exportSectionDate)
        } footer: {
            Text(.exportDateFooter)
        }
    }

    private var contentSection: some View {
        Section {
            Toggle(isOn: $request.includesAccounts) {
                Text(.exportContentIncludesAccounts)
            }
            Toggle(isOn: $request.includesSettlements) {
                Text(.exportContentIncludesSettlements)
            }
            Toggle(isOn: $request.includesVoided) {
                Text(.exportContentIncludesVoided)
            }
        } header: {
            Text(.exportSectionContent)
        } footer: {
            Text(verbatim: LedgerStringKey.exportContentFooter.string(
                arguments: [currencyCode]
            ))
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent {
                Text(verbatim: summary.transactionCount.formatted())
            } label: {
                Text(.exportSummaryTransactions)
            }
            LabeledContent {
                Text(verbatim: bookSummaryText)
            } label: {
                Text(.exportSummaryBooks)
            }
            LabeledContent {
                Text(verbatim: LedgerStringKey.exportSummaryFilesCount.string(
                    arguments: [Int64(summary.documents.count)]
                ))
            } label: {
                Text(.exportSummaryFiles)
            }

            Button {
                share()
            } label: {
                Label(.exportActionShare, systemImage: "square.and.arrow.up")
            }
            .disabled(summary.isEmpty)
        } footer: {
            Text(.exportSummaryFooter)
        }
    }

    private var bookSummaryText: String {
        guard !summary.includedBookNames.isEmpty else {
            return LedgerStringKey.exportSummaryBooksNone.string()
        }
        if summary.includedBookNames.count <= 2 {
            return ListFormatter.localizedString(byJoining: summary.includedBookNames)
        }
        return LedgerStringKey.exportSummaryBooksCount.string(
            arguments: [Int64(summary.includedBookNames.count)]
        )
    }

    private func groupSelection(fallingBackTo group: LedgerGroup) -> Binding<NSManagedObjectID> {
        Binding(
            get: { selectedGroup?.objectID ?? group.objectID },
            set: { selectedGroupID = $0 }
        )
    }

    private var defaultStartDate: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private var dateRangeBinding: Binding<Bool> {
        Binding(
            get: { request.startDate != nil || request.endDate != nil },
            set: { isOn in
                if isOn {
                    request.startDate = defaultStartDate
                    request.endDate = Date()
                } else {
                    request.startDate = nil
                    request.endDate = nil
                }
            }
        )
    }

    private func dateBinding(
        for keyPath: WritableKeyPath<LedgerExportRequest, Date?>,
        fallback: Date
    ) -> Binding<Date> {
        Binding(
            get: { request[keyPath: keyPath] ?? fallback },
            set: { request[keyPath: keyPath] = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    /// 摘要要先算出來，使用者才知道自己按下去會匯出多少東西。實際寫檔留到分享時，
    /// 每切一個開關就在磁碟上產生一組檔案並不合理。
    private func reloadSummary() {
        guard let selectedGroup else {
            summary = .empty
            return
        }
        summary = LedgerExportService().export(
            in: selectedGroup,
            request: request,
            currentBook: currentBook
        )
    }

    private func share() {
        do {
            let urls = try LedgerExportFileWriter.write(summary.documents)
            exportedFiles = ExportedFiles(urls: urls)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { DataExportView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}
