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
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LedgerTheme.primary)
            }
        }
    }
}

struct LedgerEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

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

                VStack(spacing: 7) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
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
    let title: String
    let detail: String
    let icon: String
    var tint: Color = LedgerTheme.primary

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
