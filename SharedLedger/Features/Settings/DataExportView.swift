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
                    Text("還沒有可以匯出的群組。請先建立群組並開始記帳。")
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
        .navigationTitle("匯出資料")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadSummary)
        .onChange(of: selectedGroupID) { _, _ in reloadSummary() }
        .onChange(of: request) { _, _ in reloadSummary() }
        .sheet(item: $exportedFiles) { files in
            ShareSheet(items: files.urls)
        }
        .alert("無法建立匯出檔", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "請稍後再試。")
        }
    }

    @ViewBuilder
    private var groupSection: some View {
        if groups.count > 1 {
            Section("群組") {
                Picker("群組", selection: groupSelection) {
                    ForEach(Array(groups), id: \.objectID) { group in
                        Text(group.name ?? "未命名群組").tag(group.objectID)
                    }
                }
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Picker("帳本範圍", selection: $request.scope) {
                ForEach(ReportBookScope.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

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
                                Text(book.name ?? "未命名帳本")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if request.selectedBookIDs.contains(id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(LedgerTheme.primary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            Text("範圍")
        } footer: {
            Text("交易只會匯出所選帳本的內容，每一列都標示所屬帳本。帳戶餘額屬於整個群組，不隨這個範圍改變。")
        }
    }

    private var dateSection: some View {
        Section {
            Toggle("限定日期範圍", isOn: dateRangeBinding)
            if request.startDate != nil || request.endDate != nil {
                DatePicker(
                    "開始日期",
                    selection: dateBinding(for: \.startDate, fallback: defaultStartDate),
                    displayedComponents: .date
                )
                DatePicker(
                    "結束日期",
                    selection: dateBinding(for: \.endDate, fallback: Date()),
                    displayedComponents: .date
                )
            }
        } header: {
            Text("日期")
        } footer: {
            Text("開始與結束當天的交易都會包含在內。不限定時會匯出這些帳本的全部交易。")
        }
    }

    private var contentSection: some View {
        Section {
            Toggle("包含帳戶餘額", isOn: $request.includesAccounts)
            Toggle("包含結算紀錄", isOn: $request.includesSettlements)
            Toggle("包含已作廢的交易", isOn: $request.includesVoided)
        } header: {
            Text("內容")
        } footer: {
            Text("匯出的金額是純數值，不含貨幣符號與千分位，可以直接在試算表計算；貨幣代碼（\(currencyCode)）另外獨立成一欄。")
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent("交易筆數", value: "\(summary.transactionCount)")
            LabeledContent("涵蓋帳本", value: bookSummaryText)
            LabeledContent("檔案", value: "\(summary.documents.count) 個 CSV")

            Button {
                share()
            } label: {
                Label("匯出並分享", systemImage: "square.and.arrow.up")
            }
            .disabled(summary.isEmpty)
        } footer: {
            Text("匯出檔含有群組成員的顯示名稱與交易備註，分享前請確認對象。")
        }
    }

    private var bookSummaryText: String {
        guard !summary.includedBookNames.isEmpty else { return "未選擇" }
        if summary.includedBookNames.count <= 2 {
            return summary.includedBookNames.joined(separator: "、")
        }
        return "\(summary.includedBookNames.count) 本帳本"
    }

    private var groupSelection: Binding<NSManagedObjectID> {
        Binding(
            get: { selectedGroup?.objectID ?? NSManagedObjectID() },
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
