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
                            Text(.syncViewInProgress)
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
                        Label(.syncViewRecheck, systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text(.syncViewRecheckFooter)
                }
            }

            Section {
                Label(.syncViewLocalDataTitle, systemImage: "internaldrive")
                    .font(.subheadline)
            } footer: {
                Text(.syncViewLocalDataFooter)
            }
        }
        .navigationTitle(Text(.syncTitle))
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
            Text(.syncTitle)
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
        .accessibilityLabel(
            LedgerStringKey.syncRowAccessibilityLabel.string(arguments: [monitor.state.title])
        )
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
