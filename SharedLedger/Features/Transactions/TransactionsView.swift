import SwiftUI

struct TransactionsView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case expense = "支出"
        case income = "收入"

        var id: Self { self }
    }

    @State private var filter: Filter = .all
    @State private var isPresentingNewEntry = false

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Picker("交易類型", selection: $filter) {
                        ForEach(Filter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    LedgerEmptyState(
                        systemImage: "receipt",
                        title: "帳本還是空的",
                        message: "新增第一筆共同收支，之後就能在這裡快速搜尋、篩選與核對。",
                        actionTitle: "新增第一筆交易"
                    ) {
                        isPresentingNewEntry = true
                    }
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("交易")
        .toolbar {
            Button {
                isPresentingNewEntry = true
            } label: {
                Image(systemName: "plus")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("新增交易")
        }
        .sheet(isPresented: $isPresentingNewEntry) {
            NavigationStack {
                ZStack {
                    LedgerBackground()
                    LedgerEmptyState(
                        systemImage: "square.and.pencil",
                        title: "新增交易",
                        message: "交易輸入、付款人與分攤表單會在下一個功能階段完成。"
                    )
                    .padding(LedgerTheme.pagePadding)
                }
                .navigationTitle("新增交易")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { isPresentingNewEntry = false }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

#Preview {
    NavigationStack { TransactionsView() }
}

