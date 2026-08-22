import SwiftUI
import UIKit

enum LedgerTheme {
    static let primary = dynamic(
        light: UIColor(red: 0.05, green: 0.35, blue: 0.30, alpha: 1),
        dark: UIColor(red: 0.38, green: 0.86, blue: 0.72, alpha: 1)
    )
    static let primaryStrong = dynamic(
        light: UIColor(red: 0.03, green: 0.24, blue: 0.22, alpha: 1),
        dark: UIColor(red: 0.47, green: 0.93, blue: 0.80, alpha: 1)
    )
    static let mint = dynamic(
        light: UIColor(red: 0.47, green: 0.88, blue: 0.72, alpha: 1),
        dark: UIColor(red: 0.42, green: 0.80, blue: 0.66, alpha: 1)
    )
    /// coral 與 amber 會直接畫負數金額和警示文字，不只是底色。
    /// 原本的單一色在白底只有 2～3:1 的對比，深色模式又太刺眼；
    /// 淺色改深、深色改亮，兩種外觀都拉到 4.5:1 以上。
    static let coral = dynamic(
        light: UIColor(red: 0.78, green: 0.20, blue: 0.14, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.58, blue: 0.50, alpha: 1)
    )
    static let amber = dynamic(
        light: UIColor(red: 0.54, green: 0.35, blue: 0.00, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.78, blue: 0.35, alpha: 1)
    )
    static let canvas = dynamic(
        light: UIColor(red: 0.95, green: 0.97, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.045, green: 0.07, blue: 0.065, alpha: 1)
    )
    static let surface = dynamic(
        light: .white,
        dark: UIColor(red: 0.09, green: 0.12, blue: 0.115, alpha: 1)
    )
    static let surfaceRaised = dynamic(
        light: UIColor(red: 0.98, green: 0.99, blue: 0.985, alpha: 1),
        dark: UIColor(red: 0.12, green: 0.15, blue: 0.145, alpha: 1)
    )
    static let hairline = dynamic(
        light: UIColor.black.withAlphaComponent(0.08),
        dark: UIColor.white.withAlphaComponent(0.10)
    )

    static let pagePadding: CGFloat = 20
    static let cardRadius: CGFloat = 24

    // 以下是各元件的基準尺寸。包住文字或跟文字並排的尺寸都要透過
    // `@ScaledMetric` 以這裡的值當基準，才會跟著 Dynamic Type 一起長大；
    // 寫死的 frame 配上放大的字，結果就是字被切掉。
    static let cardPadding: CGFloat = 20
    static let markSize: CGFloat = 54
    static let avatarSize: CGFloat = 42
    static let iconBadgeSize: CGFloat = 40
    static let controlMinHeight: CGFloat = 50

    /// 只有圖示的控制項至少要有這麼大的可點範圍。
    ///
    /// 這是下限而不是固定值：符號本身會跟著 Dynamic Type 長大，所以套用時一律用
    /// `minWidth`／`minHeight`，讓範圍只增不減。畫面上原本散落著 32×44、34×34 這種
    /// 尺寸，34 這一組連 HIG 的最小點擊範圍都不到。
    static let tapTargetMinimum: CGFloat = 44

    /// 純裝飾的尺寸（頭像圓、圖示底板）照字級等比放大，超過某個倍率
    /// 就只是把旁邊的文字擠掉，所以放大倍率設上限。
    ///
    /// - Parameters:
    ///   - scale: `@ScaledMetric(wrappedValue: 1, relativeTo:)` 換算出來的倍率。
    ///   - cap: 允許的最大倍率。
    static func decorativeScale(_ scale: CGFloat, cap: CGFloat = 1.5) -> CGFloat {
        min(scale, cap)
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

extension View {
    /// 跟 `.animation(_:value:)` 一樣，但使用者開了「減少動態效果」時就不動畫。
    /// 這個 App 的動畫都只是回饋，不帶資訊，關掉不會少講任何事。
    func ledgerAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(LedgerMotionSensitiveAnimation(animation: animation, value: value))
    }
}

struct LedgerMotionSensitiveAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension Color {
    /// A concrete color equivalent of SwiftUI's tertiary hierarchical style.
    /// Useful when a ternary expression requires both branches to be `Color`.
    static var tertiary: Color {
        Color(uiColor: .tertiaryLabel)
    }
}
