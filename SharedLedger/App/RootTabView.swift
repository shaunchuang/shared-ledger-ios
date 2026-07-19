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
                CategoriesRootView()
            }
            .tabItem { Label("分類", systemImage: "square.grid.2x2") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .tint(LedgerTheme.primary)
        .toolbarBackground(LedgerTheme.surface.opacity(0.94), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

#Preview {
    RootTabView()
}
