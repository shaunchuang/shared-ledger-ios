import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("資料") {
                Label("iCloud 同步", systemImage: "icloud")
                Label("匯出資料", systemImage: "square.and.arrow.up")
            }
            Section("關於") {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("設定")
    }
}

#Preview {
    NavigationStack { SettingsView() }
}

