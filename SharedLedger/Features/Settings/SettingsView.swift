import SwiftUI

struct SettingsView: View {
    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    settingsCard(title: "資料與同步", rows: [
                        SettingRow(title: "iCloud 同步", detail: "保持最新", icon: "icloud.fill", tint: LedgerTheme.primary),
                        SettingRow(title: "匯出資料", detail: "CSV、PDF", icon: "square.and.arrow.up", tint: .blue)
                    ])
                    settingsCard(title: "偏好設定", rows: [
                        SettingRow(title: "通知", detail: "結算與邀請", icon: "bell.fill", tint: LedgerTheme.amber),
                        SettingRow(title: "外觀", detail: "跟隨系統", icon: "circle.lefthalf.filled", tint: .purple)
                    ])
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

    private func settingsCard(title: String, rows: [SettingRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerSectionHeader(title: title)
            LedgerCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        row
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
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
    }
}

#Preview {
    NavigationStack { SettingsView() }
}

