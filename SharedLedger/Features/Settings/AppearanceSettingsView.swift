import SwiftUI

/// 介面外觀。
///
/// 存在 `UserDefaults` 而不是 Core Data：這是這台裝置怎麼顯示的偏好，不是帳務資料，
/// 不該同步給其他成員，也不該因為換一台裝置就把那台的設定蓋掉。
///
/// 「刪除本機個人資料」不碰它：那個動作清的是能認出使用者是誰、做過什麼的資料，
/// 而深色或淺色不屬於那一類，清掉只會讓畫面莫名其妙變回系統色。
enum LedgerAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let storageKey = "appearance.preference"

    var id: String { rawValue }

    var displayNameKey: LedgerStringKey {
        switch self {
        case .system: return .appearanceOptionSystem
        case .light: return .appearanceOptionLight
        case .dark: return .appearanceOptionDark
        }
    }

    /// `nil` 代表交給系統決定，這正是 `preferredColorScheme` 的「不干預」值。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 外觀設定。
///
/// P0-13 把深色模式列為發布門檻，而在此之前這一列是設定頁上畫得出 chevron 卻按不動的
/// 假入口。三個選項就是全部：真正該跟著系統走的其他項目（字級、減少動態效果）由
/// 系統設定提供，App 只負責照著做，不在自己的設定頁裡再開一份。
struct AppearanceSettingsView: View {
    @AppStorage(LedgerAppearance.storageKey) private var appearance = LedgerAppearance.system

    var body: some View {
        Form {
            Section {
                Picker(selection: $appearance) {
                    ForEach(LedgerAppearance.allCases) { option in
                        Text(option.displayNameKey).tag(option)
                    }
                } label: {
                    Text(.settingsRowAppearanceTitle)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(.appearanceFooter)
            }
        }
        .navigationTitle(Text(.settingsRowAppearanceTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AppearanceSettingsView() }
}
