import Foundation

/// 統計與搜尋共用的帳本範圍。
///
/// 帳戶與分類屬於群組，交易屬於單一帳本，所以任何跨帳本的數字都必須說得出自己
/// 涵蓋哪些帳本。總覽與交易搜尋共用同一個列舉，使用者在兩個畫面看到的「全部帳本」
/// 才會是同一個意思。
enum ReportBookScope: String, CaseIterable, Identifiable, Sendable {
    case allActiveBooks
    case currentBook
    case selectedBookIDs

    var id: Self { self }

    var displayName: String {
        switch self {
        case .allActiveBooks: return "全部帳本"
        case .currentBook: return "目前帳本"
        case .selectedBookIDs: return "自選帳本"
        }
    }
}
