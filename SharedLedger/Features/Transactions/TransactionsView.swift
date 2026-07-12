import SwiftUI

struct TransactionsView: View {
    @State private var isPresentingNewEntry = false

    var body: some View {
        ContentUnavailableView(
            "尚無交易",
            systemImage: "list.bullet.rectangle",
            description: Text("收入、支出與轉帳會顯示在這裡。")
        )
        .navigationTitle("交易")
        .toolbar {
            Button("新增", systemImage: "plus") {
                isPresentingNewEntry = true
            }
        }
        .sheet(isPresented: $isPresentingNewEntry) {
            NavigationStack {
                Text("新增交易表單將在下一個里程碑完成。")
                    .padding()
                    .navigationTitle("新增交易")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { isPresentingNewEntry = false }
                        }
                    }
            }
        }
    }
}

#Preview {
    NavigationStack { TransactionsView() }
}

