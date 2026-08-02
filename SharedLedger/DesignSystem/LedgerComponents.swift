import SwiftUI

struct LedgerBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LedgerTheme.canvas
            // 這圈光暈只是氣氛；開了「降低透明度」的人要的是乾淨的實色底。
            if !reduceTransparency {
                Circle()
                    .fill(LedgerTheme.mint.opacity(0.13))
                    .frame(width: 260, height: 260)
                    .blur(radius: 18)
                    .offset(x: 100, y: -150)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct LedgerCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = LedgerTheme.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: LedgerTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LedgerTheme.cardRadius)
                    .stroke(LedgerTheme.hairline)
            }
            .shadow(color: .black.opacity(0.035), radius: 16, y: 7)
    }
}

struct LedgerMark: View {
    var size: CGFloat = LedgerTheme.markSize

    @ScaledMetric(relativeTo: .title) private var typeScale: CGFloat = 1

    private var scaledSize: CGFloat { size * LedgerTheme.decorativeScale(typeScale) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scaledSize * 0.31)
                .fill(
                    LinearGradient(
                        colors: [LedgerTheme.primaryStrong, LedgerTheme.primary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "person.2.fill")
                .font(.system(size: scaledSize * 0.39, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: scaledSize, height: scaledSize)
        .accessibilityHidden(true)
    }
}

struct LedgerAvatar: View {
    let name: String
    var size: CGFloat = LedgerTheme.avatarSize

    // 縮寫是文字，圓框是包住文字的容器：兩個一起放大，字才不會被圓形切掉。
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    private var scaledSize: CGFloat { size * LedgerTheme.decorativeScale(typeScale) }

    private var initials: String {
        let parts = name.split(separator: " ")
        let value = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: scaledSize * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(LedgerTheme.primaryStrong)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: scaledSize, height: scaledSize)
            .background(LedgerTheme.mint.opacity(0.24), in: Circle())
            .overlay { Circle().stroke(LedgerTheme.primary.opacity(0.12)) }
            .accessibilityLabel(name)
    }
}

struct LedgerSectionHeader: View {
    private let title: LedgerStringKey

    init(title: LedgerStringKey) {
        self.title = title
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct LedgerEmptyState: View {
    private let systemImage: String
    private let title: Text
    private let message: Text
    private let actionTitle: Text?
    private let action: (() -> Void)?

    @ScaledMetric(relativeTo: .title) private var typeScale: CGFloat = 1

    // 空狀態的插圖本來就大，放大倍率比其他元件再收斂一點，
    // 免得在最大字級把標題和按鈕整個推出畫面。
    private var artScale: CGFloat { LedgerTheme.decorativeScale(typeScale, cap: 1.3) }

    init(
        systemImage: String,
        title: LedgerStringKey,
        message: LedgerStringKey,
        actionTitle: LedgerStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(
            systemImage: systemImage,
            title: Text(title),
            message: Text(message),
            actionTitle: actionTitle.map { Text($0) },
            action: action
        )
    }

    /// 說明文字帶參數時由呼叫端先組好，但仍必須來自 catalog 的鍵——
    /// `LedgerStringKey.string(arguments:)` 的結果包進 `Text(verbatim:)` 再傳進來。
    init(
        systemImage: String,
        title: LedgerStringKey,
        message: Text,
        actionTitle: LedgerStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(
            systemImage: systemImage,
            title: Text(title),
            message: message,
            actionTitle: actionTitle.map { Text($0) },
            action: action
        )
    }

    private init(
        systemImage: String,
        title: Text,
        message: Text,
        actionTitle: Text?,
        action: (() -> Void)?
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        LedgerCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(LedgerTheme.mint.opacity(0.18))
                        .frame(width: 104 * artScale, height: 104 * artScale)
                    Circle()
                        .stroke(LedgerTheme.primary.opacity(0.12), lineWidth: 1)
                        .frame(width: 80 * artScale, height: 80 * artScale)
                    Image(systemName: systemImage)
                        .font(.system(size: 34 * artScale, weight: .medium))
                        .foregroundStyle(LedgerTheme.primary)
                }
                // 圖示只是裝飾，說明全在標題與內文；讓 VoiceOver 唸出符號名稱只是噪音。
                .accessibilityHidden(true)

                VStack(spacing: 7) {
                    title
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    message
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let actionTitle, let action {
                    Button(action: action) { actionTitle }
                        .buttonStyle(LedgerPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}

struct LedgerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    /// `ButtonStyle` 本身不是 `View`，讀不到 environment；
    /// 「減少動態效果」和 Dynamic Type 都得在這個內層 view 裡拿。
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ScaledMetric(relativeTo: .headline) private var scaledMinHeight: CGFloat = LedgerTheme.controlMinHeight
        @ScaledMetric(relativeTo: .headline) private var horizontalPadding: CGFloat = 22

        /// 小字級時 `@ScaledMetric` 會回傳小於 1 的倍率。按鈕高度是觸控目標，
        /// 縮下去會低於 HIG 的 44pt 下限，所以只准往上長。
        private var minHeight: CGFloat { max(scaledMinHeight, LedgerTheme.controlMinHeight) }

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.white)
                // 最大字級的按鈕文字換行是正常的，寧可長高也不要被截掉。
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 8)
                .frame(minHeight: minHeight)
                .background(
                    LinearGradient(
                        colors: [LedgerTheme.primaryStrong, LedgerTheme.primary],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .opacity(configuration.isPressed ? 0.82 : 1)
                // 縮放本身就是動態效果，關掉之後只留下不會動的透明度回饋。
                .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
                .ledgerAnimation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

struct LedgerNavRow: View {
    private let title: Text
    private let detail: Text
    private let icon: String
    private let tint: Color

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: LedgerStringKey,
        detail: LedgerStringKey,
        icon: String,
        tint: Color = LedgerTheme.primary
    ) {
        self.init(title: Text(title), detail: Text(detail), icon: icon, tint: tint)
    }

    /// 說明文字是群組名稱、帳本名稱這類資料時用這一個；標題一律走鍵。
    init(
        title: LedgerStringKey,
        detail: String,
        icon: String,
        tint: Color = LedgerTheme.primary
    ) {
        self.init(title: Text(title), detail: Text(verbatim: detail), icon: icon, tint: tint)
    }

    private init(title: Text, detail: Text, icon: String, tint: Color) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconBadge(systemImage: icon, tint: tint)
            labels
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // 標題與說明是同一列的一句話，分開唸只會讓人多滑一次。
        .accessibilityElement(children: .combine)
    }

    /// 標題和說明在一般字級並排；到了輔助字級同一列塞不下兩段文字，
    /// 再擠下去就是兩邊都被截斷，所以改成上下排。
    private var labels: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))

        return layout {
            title
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LedgerIconBadge: View {
    let systemImage: String
    var tint: Color = LedgerTheme.primary

    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    private var size: CGFloat { LedgerTheme.iconBadgeSize * LedgerTheme.decorativeScale(typeScale) }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17 * LedgerTheme.decorativeScale(typeScale), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.325))
            .accessibilityHidden(true)
    }
}

/// An inline explanation shown in place of an action the current user cannot take,
/// so a restriction is visible before the user commits to a form.
struct LedgerNotice: View {
    let message: String
    var systemImage: String = "lock"
    var tint: Color = LedgerTheme.amber

    var body: some View {
        LedgerCard {
            HStack(alignment: .top, spacing: 12) {
                // 用文字樣式而不是寫死的 pt，圖示才會跟著旁邊的說明文字一起放大。
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
