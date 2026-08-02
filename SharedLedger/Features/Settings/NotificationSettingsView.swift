import SwiftUI
import UIKit

extension LedgerNotificationAuthorization {
    var systemImage: String {
        switch self {
        case .authorized: return "bell.badge.fill"
        case .provisional: return "bell.badge"
        case .notDetermined: return "bell"
        case .denied: return "bell.slash.fill"
        case .unavailable: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .authorized: return LedgerTheme.primary
        case .provisional: return .blue
        case .notDetermined, .unavailable: return LedgerTheme.amber
        case .denied: return LedgerTheme.coral
        }
    }
}

/// 通知與提醒設定。
///
/// 三個種類各自一個開關，而且不論系統授權與否都可以調整：使用者可能先在這裡挑好要
/// 收什麼，再決定要不要授權。授權只有在使用者主動按下去時才詢問。
struct NotificationSettingsView: View {
    @ObservedObject var coordinator: LedgerNotificationCoordinator
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LedgerIconBadge(
                        systemImage: coordinator.authorization.systemImage,
                        tint: coordinator.authorization.tint
                    )
                    Text(coordinator.authorization.titleKey)
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)

                Text(coordinator.authorization.detailKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if coordinator.authorization.canRequest {
                    Button {
                        Task { await coordinator.requestAuthorization() }
                    } label: {
                        Label(.notificationSettingsEnable, systemImage: "bell.badge")
                    }
                } else if coordinator.authorization == .denied {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else {
                            return
                        }
                        openURL(url)
                    } label: {
                        Label(.notificationSettingsOpenSystemSettings, systemImage: "gear")
                    }
                }
            }

            Section {
                ForEach(LedgerNotificationCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.titleKey)
                                .font(.subheadline.weight(.medium))
                            Text(category.detailKey)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(.notificationSettingsCategoriesHeader)
            } footer: {
                Text(verbatim: categoriesFooter)
            }

            Section {
                Label(.notificationSettingsAppUsableTitle, systemImage: "checkmark.circle")
                    .font(.subheadline)
            } footer: {
                Text(.notificationSettingsAppUsableFooter)
            }
        }
        .navigationTitle(Text(.notificationTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refreshAuthorization() }
    }

    /// 沒授權時仍然照常顯示開關，只是補一句說明現在不會送出。把開關鎖起來反而讓人
    /// 以為要先授權才能設定。
    private var categoriesFooter: String {
        guard coordinator.authorization.allowsDelivery else {
            return LedgerStringKey.notificationSettingsCategoriesFooterNotAllowed.string()
        }
        guard coordinator.preferences.isAnyCategoryEnabled else {
            return LedgerStringKey.notificationSettingsCategoriesFooterAllDisabled.string()
        }
        return LedgerStringKey.notificationSettingsCategoriesFooterNormal.string()
    }

    private func binding(for category: LedgerNotificationCategory) -> Binding<Bool> {
        Binding(
            get: { coordinator.preferences.isEnabled(category) },
            set: { coordinator.setEnabled($0, for: category) }
        )
    }
}

/// 設定頁上的通知狀態列。
struct NotificationSettingsRow: View {
    @ObservedObject var coordinator: LedgerNotificationCoordinator

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconBadge(
                systemImage: coordinator.authorization.systemImage,
                tint: coordinator.authorization.tint
            )
            Text(.notificationTitle)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(verbatim: summary)
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
            LedgerStringKey.notificationRowAccessibilityLabel.string(arguments: [summary])
        )
    }

    private var summary: String {
        guard coordinator.authorization.allowsDelivery else {
            return coordinator.authorization.title
        }
        let enabled = coordinator.preferences.enabledCategories.count
        switch enabled {
        case 0: return LedgerStringKey.notificationRowSummaryAllOff.string()
        case LedgerNotificationCategory.allCases.count:
            return LedgerStringKey.notificationRowSummaryAllOn.string()
        default:
            return LedgerStringKey.notificationRowSummaryPartial
                .string(arguments: [Int64(enabled)])
        }
    }
}

/// 預覽不碰 `UNUserNotificationCenter`：預覽環境沒有真正的授權狀態可問。
private struct PreviewNotificationScheduler: LedgerNotificationScheduling {
    func authorizationStatus() async -> LedgerNotificationAuthorization { .authorized }
    func requestAuthorization() async -> LedgerNotificationAuthorization { .authorized }
    func schedule(_ requests: [LedgerNotificationRequest]) async {}
}

#Preview {
    NavigationStack {
        NotificationSettingsView(
            coordinator: LedgerNotificationCoordinator(
                persistence: PersistenceController(inMemory: true),
                store: LedgerNotificationStore(
                    defaults: UserDefaults(suiteName: "NotificationSettingsPreview") ?? .standard
                ),
                scheduler: PreviewNotificationScheduler()
            )
        )
    }
}
