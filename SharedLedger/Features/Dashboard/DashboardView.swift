import SwiftUI

struct DashboardView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SummaryCard(
                    title: "本月支出",
                    value: "$0",
                    systemImage: "arrow.up.right",
                    tint: .orange
                )
                SummaryCard(
                    title: "待結算",
                    value: "$0",
                    systemImage: "arrow.left.arrow.right",
                    tint: .blue
                )
                ContentUnavailableView(
                    "尚無交易",
                    systemImage: "tray",
                    description: Text("建立群組並新增第一筆共同支出。")
                )
            }
            .padding()
        }
        .navigationTitle("總覽")
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading) {
                Text(title).foregroundStyle(.secondary)
                Text(value).font(.title2.bold())
            }
            Spacer()
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.quaternary)
        }
    }
}

#Preview {
    NavigationStack { DashboardView() }
}

