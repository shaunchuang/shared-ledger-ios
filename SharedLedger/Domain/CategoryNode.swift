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

/// 新群組的起始目錄，也能由既有群組主動補入。名稱寫入後就是使用者資料；
/// 不自動改名、搬移或重分類歷史交易，使用者可繼續在任一層新增子分類。
enum DefaultCategoryCatalog {
    static let categories: [CategoryNode] = [
        CategoryNode(name: .defaultCategoryFood, children: [
            CategoryNode(name: .defaultCategoryFoodMeals),
            CategoryNode(name: .defaultCategoryFoodDrinks),
            CategoryNode(name: .defaultCategoryFoodGroceries),
            CategoryNode(name: .defaultCategoryFoodEatingOut)
        ]),
        CategoryNode(name: .defaultCategoryClothing, children: [
            CategoryNode(name: .defaultCategoryEverydayClothing),
            CategoryNode(name: .defaultCategoryClothingShoes),
            CategoryNode(name: .defaultCategoryClothingAccessories),
            CategoryNode(name: .defaultCategoryEverydayBeauty)
        ]),
        CategoryNode(name: .defaultCategoryHome, children: [
            CategoryNode(name: .defaultCategoryHomeRent),
            CategoryNode(name: .defaultCategoryHomeMortgage),
            CategoryNode(name: .defaultCategoryHomeFurniture),
            CategoryNode(name: .defaultCategoryHomeUtilities),
            CategoryNode(name: .defaultCategoryHomeTelecom),
            CategoryNode(name: .defaultCategoryHomeHousehold)
        ]),
        CategoryNode(name: .defaultCategoryTransport, children: [
            CategoryNode(name: .defaultCategoryTransportPublic, children: [
                CategoryNode(name: .defaultCategoryTransportBus),
                CategoryNode(name: .defaultCategoryTransportMetro),
                CategoryNode(name: .defaultCategoryTransportTrain)
            ]),
            CategoryNode(name: .defaultCategoryTransportTaxi),
            CategoryNode(name: .defaultCategoryTransportCycling),
            CategoryNode(name: .defaultCategoryTransportScooter),
            CategoryNode(name: .defaultCategoryTransportCar, children: [
                CategoryNode(name: .defaultCategoryTransportFuel),
                CategoryNode(name: .defaultCategoryTransportParking),
                CategoryNode(name: .defaultCategoryTransportTolls),
                CategoryNode(name: .defaultCategoryTransportMaintenance),
                CategoryNode(name: .defaultCategoryTransportCarWash),
                CategoryNode(name: .defaultCategoryTransportTires)
            ])
        ]),
        CategoryNode(name: .defaultCategoryEducation, children: [
            CategoryNode(name: .defaultCategoryEducationTuition),
            CategoryNode(name: .defaultCategoryEducationTutoring),
            CategoryNode(name: .defaultCategoryEducationBooks),
            CategoryNode(name: .defaultCategoryEducationSkills)
        ]),
        CategoryNode(name: .defaultCategoryLeisure, children: [
            CategoryNode(name: .defaultCategoryLeisureMovies),
            CategoryNode(name: .defaultCategoryLeisureTravel),
            CategoryNode(name: .defaultCategoryLeisureSports),
            CategoryNode(name: .defaultCategoryLeisureGames),
            CategoryNode(name: .defaultCategoryLeisureSubscriptions),
            CategoryNode(name: .defaultCategoryLeisureActivities)
        ]),
        CategoryNode(name: .defaultCategoryHealth, children: [
            CategoryNode(name: .defaultCategoryHealthMedicine),
            CategoryNode(name: .defaultCategoryHealthInsurance)
        ]),
        CategoryNode(name: .defaultCategoryGifts),
        CategoryNode(name: .defaultCategoryIncome, children: [
            CategoryNode(name: .defaultCategoryIncomeSalary),
            CategoryNode(name: .defaultCategoryIncomeBonus),
            CategoryNode(name: .defaultCategoryIncomeOther)
        ]),
        CategoryNode(name: .defaultCategoryOther)
    ]
}
