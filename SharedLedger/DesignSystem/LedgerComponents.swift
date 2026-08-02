import SwiftUI

struct LedgerBackground: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LedgerTheme.canvas
            Circle()
                .fill(LedgerTheme.mint.opacity(0.13))
                .frame(width: 260, height: 260)
                .blur(radius: 18)
                .offset(x: 100, y: -150)
        }
        .ignoresSafeArea()
    }
}

struct LedgerCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
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
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31)
                .fill(
                    LinearGradient(
                        colors: [LedgerTheme.primaryStrong, LedgerTheme.primary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LedgerAvatar: View {
    let name: String
    var size: CGFloat = 42

    private var initials: String {
        let parts = name.split(separator: " ")
        let value = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(LedgerTheme.primaryStrong)
            .frame(width: size, height: size)
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
            Spacer()
        }
    }
}

struct LedgerEmptyState: View {
    private let systemImage: String
    private let title: Text
    private let message: Text
    private let actionTitle: Text?
    private let action: (() -> Void)?

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
                        .frame(width: 104, height: 104)
                    Circle()
                        .stroke(LedgerTheme.primary.opacity(0.12), lineWidth: 1)
                        .frame(width: 80, height: 80)
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(LedgerTheme.primary)
                }
                // 圖示只是裝飾，說明全在標題與內文；讓 VoiceOver 唸出符號名稱只是噪音。
                .accessibilityHidden(true)

                VStack(spacing: 7) {
                    title
                        .font(.title3.weight(.bold))
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
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(minHeight: 50)
            .background(
                LinearGradient(
                    colors: [LedgerTheme.primaryStrong, LedgerTheme.primary],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct LedgerNavRow: View {
    private let title: Text
    private let detail: Text
    private let icon: String
    private let tint: Color

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
            title
                .font(.subheadline.weight(.medium))
            Spacer()
            detail
                .font(.caption)
                .foregroundStyle(.secondary)
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
}

struct LedgerIconBadge: View {
    let systemImage: String
    var tint: Color = LedgerTheme.primary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
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
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
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
