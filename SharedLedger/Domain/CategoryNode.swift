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

    /// 內建分類的名稱來自 catalog；名稱一旦寫進 Core Data 就是使用者自己的資料，
    /// 之後改名或切換語言都不會再回頭動它。
    init(id: UUID = UUID(), name key: LedgerStringKey, children: [CategoryNode] = []) {
        self.init(id: id, name: key.string(), children: children)
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
            name: .defaultCategoryFood,
            children: [
                CategoryNode(name: .defaultCategoryFoodMeals),
                CategoryNode(name: .defaultCategoryFoodDrinks),
                CategoryNode(name: .defaultCategoryFoodEatingOut)
            ]
        ),
        CategoryNode(
            name: .defaultCategoryHome,
            children: [
                CategoryNode(name: .defaultCategoryHomeRent),
                CategoryNode(name: .defaultCategoryHomeUtilities),
                CategoryNode(name: .defaultCategoryHomeTelecom),
                CategoryNode(name: .defaultCategoryHomeHousehold)
            ]
        ),
        CategoryNode(
            name: .defaultCategoryTransport,
            children: [
                CategoryNode(name: .defaultCategoryTransportPublic),
                CategoryNode(name: .defaultCategoryTransportTaxi),
                CategoryNode(name: .defaultCategoryTransportVehicle)
            ]
        ),
        CategoryNode(
            name: .defaultCategoryEveryday,
            children: [
                CategoryNode(name: .defaultCategoryEverydayGoods),
                CategoryNode(name: .defaultCategoryEverydayClothing),
                CategoryNode(name: .defaultCategoryEverydayBeauty)
            ]
        ),
        CategoryNode(
            name: .defaultCategoryHealth,
            children: [
                CategoryNode(name: .defaultCategoryHealthMedicine),
                CategoryNode(name: .defaultCategoryHealthInsurance)
            ]
        ),
        CategoryNode(
            name: .defaultCategoryLeisure,
            children: [
                CategoryNode(name: .defaultCategoryLeisureTravel),
                CategoryNode(name: .defaultCategoryLeisureSubscriptions),
                CategoryNode(name: .defaultCategoryLeisureActivities)
            ]
        ),
        CategoryNode(
            name: .defaultCategoryEducation,
            children: [
                CategoryNode(name: .defaultCategoryEducationTuition),
                CategoryNode(name: .defaultCategoryEducationBooks)
            ]
        ),
        CategoryNode(name: .defaultCategoryGifts),
        CategoryNode(
            name: .defaultCategoryIncome,
            children: [
                CategoryNode(name: .defaultCategoryIncomeSalary),
                CategoryNode(name: .defaultCategoryIncomeBonus),
                CategoryNode(name: .defaultCategoryIncomeOther)
            ]
        ),
        CategoryNode(name: .defaultCategoryOther)
    ]
}

