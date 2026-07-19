import SwiftUI

struct DashboardView: View {
    var body: some View {
        ZStack {
            LedgerBackground()
            ScrollView {
                LazyVStack(spacing: 18) {
                    welcomeHeader
                    balanceHero
                    metricGrid
                    gettingStartedCard
                }
                .padding(.horizontal, LedgerTheme.pagePadding)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("總覽")
        .navigationBarTitleDisplayMode(.large)
    }

    private var welcomeHeader: some View {
        HStack(spacing: 13) {
            LedgerMark(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Shared Ledger")
                    .font(.headline)
                Text("一起記，算得更清楚")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "bell")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(LedgerTheme.surface, in: Circle())
                .overlay { Circle().stroke(LedgerTheme.hairline) }
                .accessibilityLabel("通知")
        }
    }

    private var balanceHero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("本月共同支出", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                Text("本月")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("$0")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("新增第一筆支出後，這裡會顯示群組趨勢")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
            }

            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index == 6 ? 0.82 : 0.18))
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(8 + index * 3))
                }
            }
            .frame(height: 30, alignment: .bottom)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.25, blue: 0.23),
                    Color(red: 0.08, green: 0.43, blue: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.07))
                .frame(width: 150, height: 150)
                .offset(x: 45, y: -55)
                .allowsHitTesting(false)
        }
        .shadow(color: LedgerTheme.primary.opacity(0.20), radius: 24, y: 12)
    }

    private var metricGrid: some View {
        HStack(spacing: 12) {
            MetricTile(
                title: "待結算",
                value: "$0",
                detail: "目前已平衡",
                systemImage: "arrow.left.arrow.right",
                tint: LedgerTheme.amber
            )
            MetricTile(
                title: "活躍群組",
                value: "0",
                detail: "開始建立群組",
                systemImage: "person.3.fill",
                tint: LedgerTheme.primary
            )
        }
    }

    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            LedgerSectionHeader(title: "開始共同記帳")
            LedgerCard {
                VStack(spacing: 0) {
                    OnboardingStep(number: "1", title: "建立群組", detail: "加入家人、朋友或旅伴")
                    Divider().padding(.leading, 52)
                    OnboardingStep(number: "2", title: "新增帳戶", detail: "現金、銀行或共同基金")
                    Divider().padding(.leading, 52)
                    OnboardingStep(number: "3", title: "記錄第一筆", detail: "選擇付款人與分攤方式")
                }
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        LedgerCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                LedgerIconBadge(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title2.weight(.bold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct OnboardingStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Text(number)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LedgerTheme.primaryStrong)
                .frame(width: 34, height: 34)
                .background(LedgerTheme.mint.opacity(0.22), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
    }
}

#Preview {
    NavigationStack { DashboardView() }
}
