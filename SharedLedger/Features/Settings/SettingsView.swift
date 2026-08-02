import SwiftUI

struct SettingsView: View {
    /// 監看跟著設定頁的生命週期存活，observer 在 deinit 一併移除。
    ///
    /// 沒有對應的 stop：`NWPathMonitor` 一旦 `cancel()` 就不能重新啟動，為了離開畫面
    /// 省下的那點成本而每次都重建一個，反而更容易出錯。`start()` 本身可以重複呼叫。
    @StateObject private var syncMonitor = SyncStatusMonitor(
        container: PersistenceController.shared.container
    )

    /// 通知協調器由 App 層建立並持有：它在背景監看遠端變更，生命週期不能綁在設定頁上。
    @EnvironmentObject private var notifications: LedgerNotificationCoordinator

    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    groupManagementCard
                    syncCard
                    dataCard
                    preferencesCard
                    Text("Shared Ledger  ·  版本 0.1.0")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("設定")
        .onAppear { syncMonitor.start() }
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "同步")
            LedgerCard(padding: 0) {
                NavigationLink {
                    SyncStatusView(monitor: syncMonitor)
                } label: {
                    SyncStatusRow(monitor: syncMonitor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "偏好設定")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink {
                        NotificationSettingsView(coordinator: notifications)
                    } label: {
                        NotificationSettingsRow(coordinator: notifications)
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 68)

                    SettingRow(
                        title: "外觀",
                        detail: "跟隨系統",
                        icon: "circle.lefthalf.filled",
                        tint: .purple
                    )
                }
            }
        }
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "資料")
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    NavigationLink {
                        DataExportView()
                    } label: {
                        SettingRow(
                            title: "匯出資料",
                            detail: "CSV",
                            icon: "square.and.arrow.up",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)

                    Divider().padding(.leading, 68)

                    NavigationLink {
                        DataPrivacyView()
                    } label: {
                        SettingRow(
                            title: "刪除資料",
                            detail: "群組與帳務",
                            icon: "trash",
                            tint: LedgerTheme.coral
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var groupManagementCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: "共同記帳")
            LedgerCard(padding: 0) {
                NavigationLink {
                    GroupsView()
                } label: {
                    SettingRow(
                        title: "群組管理",
                        detail: "成員、帳本與帳戶",
                        icon: "person.3.fill",
                        tint: LedgerTheme.primary
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var profileCard: some View {
        LedgerCard {
            HStack(spacing: 15) {
                LedgerMark(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared Ledger")
                        .font(.headline)
                    Text("你的共同記帳空間")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

}

private struct SettingRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconBadge(systemImage: icon, tint: tint)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(detail)
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
    }
}

#Preview {
    let persistence = PersistenceController(inMemory: true)
    NavigationStack { SettingsView() }
        .environment(\.managedObjectContext, persistence.container.viewContext)
        .environmentObject(LedgerNotificationCoordinator(persistence: persistence))
}
