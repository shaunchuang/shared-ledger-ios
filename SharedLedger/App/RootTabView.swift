import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label("總覽", systemImage: "chart.pie") }

            NavigationStack {
                TransactionsView()
            }
            .tabItem { Label("交易", systemImage: "list.bullet.rectangle") }

            NavigationStack {
                GroupsView()
            }
            .tabItem { Label("群組", systemImage: "person.3") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootTabView()
}

