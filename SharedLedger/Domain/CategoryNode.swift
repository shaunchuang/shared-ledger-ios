import Foundation

struct CategoryNode: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var children: [CategoryNode]

    init(id: UUID = UUID(), name: String, children: [CategoryNode] = []) {
        self.id = id
        self.name = name
        self.children = children
    }

    var depth: Int {
        guard let deepestChild = children.map(\.depth).max() else { return 1 }
        return deepestChild + 1
    }

    func contains(id targetID: UUID) -> Bool {
        id == targetID || children.contains { $0.contains(id: targetID) }
    }
}

/// 建立群組時套用的內建分類。
///
/// 一個沒有任何分類的新群組，第一筆交易只能記成「未分類」，之後的報表也就沒有東西可以
/// 拆。這份目錄只是起點：它跟其他分類一樣屬於群組，可以改名、排序、合併或封存，也可以
/// 在建立群組時整份關掉。層級刻意只做兩層，超過兩層的細分留給使用者自己決定。
enum DefaultCategoryCatalog {
    static let categories: [CategoryNode] = [
        CategoryNode(
            name: "餐飲",
            children: [
                CategoryNode(name: "三餐"),
                CategoryNode(name: "飲料點心"),
                CategoryNode(name: "外食聚餐")
            ]
        ),
        CategoryNode(
            name: "居家",
            children: [
                CategoryNode(name: "房租房貸"),
                CategoryNode(name: "水電瓦斯"),
                CategoryNode(name: "網路電信"),
                CategoryNode(name: "家用雜支")
            ]
        ),
        CategoryNode(
            name: "交通",
            children: [
                CategoryNode(name: "大眾運輸"),
                CategoryNode(name: "計程車"),
                CategoryNode(name: "汽機車")
            ]
        ),
        CategoryNode(
            name: "生活",
            children: [
                CategoryNode(name: "日用品"),
                CategoryNode(name: "服飾"),
                CategoryNode(name: "美容保養")
            ]
        ),
        CategoryNode(
            name: "醫療健康",
            children: [
                CategoryNode(name: "門診用藥"),
                CategoryNode(name: "保險")
            ]
        ),
        CategoryNode(
            name: "娛樂",
            children: [
                CategoryNode(name: "旅遊"),
                CategoryNode(name: "訂閱服務"),
                CategoryNode(name: "休閒活動")
            ]
        ),
        CategoryNode(
            name: "教育",
            children: [
                CategoryNode(name: "學費"),
                CategoryNode(name: "書籍課程")
            ]
        ),
        CategoryNode(name: "人情往來"),
        CategoryNode(
            name: "收入",
            children: [
                CategoryNode(name: "薪資"),
                CategoryNode(name: "獎金"),
                CategoryNode(name: "其他收入")
            ]
        ),
        CategoryNode(name: "其他")
    ]
}

