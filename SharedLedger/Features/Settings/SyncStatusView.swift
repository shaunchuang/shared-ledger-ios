import SwiftUI

extension LedgerSyncState {
    var systemImage: String {
        switch self {
        case .signedOut: return "icloud.slash"
        case .restricted: return "lock.icloud"
        case .undetermined: return "icloud"
        case .offline: return "wifi.slash"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .upToDate: return "checkmark.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }

    var tint: Color {
        switch self {
        case .upToDate: return LedgerTheme.primary
        case .syncing: return .blue
        case .offline, .undetermined: return LedgerTheme.amber
        case .signedOut, .restricted, .failed: return LedgerTheme.coral
        }
    }
}

/// iCloud 同步狀態的細節畫面。
struct SyncStatusView: View {
    @ObservedObject var monitor: SyncStatusMonitor

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LedgerIconBadge(
                        systemImage: monitor.state.systemImage,
                        tint: monitor.state.tint
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.state.title)
                            .font(.headline)
                        if case .syncing = monitor.state {
                            Text("進行中")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if case .syncing = monitor.state {
                        ProgressView()
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                Text(monitor.state.detail(lastSuccessfulSync: monitor.lastSuccessfulSync))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if monitor.state.suggestsRetry {
                Section {
                    Button {
                        monitor.refresh()
                    } label: {
                        Label("重新檢查", systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text("iCloud 會自行安排同步時機，App 無法強制立即上傳或下載。這個動作只會重新確認目前狀態。")
                }
            }

            Section {
                Label("本機資料完整保存", systemImage: "internaldrive")
                    .font(.subheadline)
            } footer: {
                Text("不論同步狀態如何，已經記錄的帳務都保存在這台裝置上，可以繼續新增與編輯；恢復連線後會自動補送。")
            }
        }
        .navigationTitle("iCloud 同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 設定頁上的同步狀態列。
struct SyncStatusRow: View {
    @ObservedObject var monitor: SyncStatusMonitor

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconBadge(
                systemImage: monitor.state.systemImage,
                tint: monitor.state.tint
            )
            Text("iCloud 同步")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(monitor.state.title)
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
        .accessibilityLabel("iCloud 同步，\(monitor.state.title)")
    }
}

#Preview {
    NavigationStack {
        SyncStatusView(
            monitor: SyncStatusMonitor(
                accountStatusProvider: { .available },
                monitorsNetwork: false
            )
        )
    }
}
