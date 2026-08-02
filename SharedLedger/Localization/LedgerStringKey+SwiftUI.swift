import SwiftUI

/// 讓畫面可以直接寫 `Text(.settingsTitle)`。
///
/// 刻意不提供接受字串常值的入口：畫面上只要出現 `Text("設定")`，那段文字就不會進
/// catalog，也不會被完整性測試看見。要顯示文字就得先有一個鍵。
extension Text {
    init(_ key: LedgerStringKey) {
        self.init(key.resource)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ key: LedgerStringKey, systemImage name: String) {
        self.init(
            title: { Text(key) },
            icon: { Image(systemName: name) }
        )
    }
}
