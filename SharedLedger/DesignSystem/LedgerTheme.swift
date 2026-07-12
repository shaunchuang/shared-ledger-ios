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
    static let mint = Color(red: 0.47, green: 0.88, blue: 0.72)
    static let coral = Color(red: 0.96, green: 0.45, blue: 0.36)
    static let amber = Color(red: 0.95, green: 0.68, blue: 0.24)
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

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

