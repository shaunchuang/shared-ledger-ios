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

    /// Keep the path to matching descendants so a search result still has context.
    func matching(_ query: String) -> CategoryNode? {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !name.localizedStandardContains(keyword) else { return self }
        let matches = children.compactMap { $0.matching(keyword) }
        guard !matches.isEmpty else { return nil }
        return CategoryNode(id: id, name: name, children: matches)
    }
}

/// 新群組的起始目錄，也能由既有群組主動補入。名稱寫入後就是使用者資料；
/// 不自動改名、搬移或重分類歷史交易，使用者可繼續在任一層新增子分類。
enum DefaultCategoryCatalog {
    // Scope and research sources: Docs/MVP.md, "完整生活分類目錄".
    static let categories: [CategoryNode] = [
        foodCategories,
        clothingCategories,
        homeCategories,
        transportCategories,
        educationCategories,
        leisureCategories,
        dailyCategories,
        digitalCategories,
        healthCategories,
        socialInsuranceCategories,
        childcareCategories,
        careCategories,
        petsCategories,
        giftsCategories,
        taxCategories,
        financeCategories,
        incomeCategories,
        otherCategories
    ]

    private static let foodCategories =
        CategoryNode(name: .defaultCategoryFood, children: [
            CategoryNode(name: .defaultCategoryFoodMeals, children: [
                CategoryNode(name: .defaultCategoryFoodMealsBreakfast),
                CategoryNode(name: .defaultCategoryFoodMealsLunch),
                CategoryNode(name: .defaultCategoryFoodMealsDinner),
                CategoryNode(name: .defaultCategoryFoodMealsLateNight),
                CategoryNode(name: .defaultCategoryFoodMealsSchoolWork)
            ]),
            CategoryNode(name: .defaultCategoryFoodDrinks, children: [
                CategoryNode(name: .defaultCategoryFoodDrinksTea),
                CategoryNode(name: .defaultCategoryFoodDrinksCoffee),
                CategoryNode(name: .defaultCategoryFoodDrinksWater),
                CategoryNode(name: .defaultCategoryFoodDrinksJuice),
                CategoryNode(name: .defaultCategoryFoodDrinksDesserts),
                CategoryNode(name: .defaultCategoryFoodDrinksSnacks)
            ]),
            CategoryNode(name: .defaultCategoryFoodGroceries, children: [
                CategoryNode(name: .defaultCategoryFoodGroceriesGrains),
                CategoryNode(name: .defaultCategoryFoodGroceriesVegetables),
                CategoryNode(name: .defaultCategoryFoodGroceriesFruit),
                CategoryNode(name: .defaultCategoryFoodGroceriesMeat),
                CategoryNode(name: .defaultCategoryFoodGroceriesSeafood),
                CategoryNode(name: .defaultCategoryFoodGroceriesEggsDairy),
                CategoryNode(name: .defaultCategoryFoodGroceriesSoy),
                CategoryNode(name: .defaultCategoryFoodGroceriesSeasoning),
                CategoryNode(name: .defaultCategoryFoodGroceriesFrozen),
                CategoryNode(name: .defaultCategoryFoodGroceriesBaking)
            ]),
            CategoryNode(name: .defaultCategoryFoodEatingOut, children: [
                CategoryNode(name: .defaultCategoryFoodEatingOutRestaurant),
                CategoryNode(name: .defaultCategoryFoodEatingOutBuffet),
                CategoryNode(name: .defaultCategoryFoodEatingOutDelivery),
                CategoryNode(name: .defaultCategoryFoodEatingOutDeliveryFee),
                CategoryNode(name: .defaultCategoryFoodEatingOutCatering)
            ]),
            CategoryNode(name: .defaultCategoryFoodAlcohol)
        ])

    private static let clothingCategories =
        CategoryNode(name: .defaultCategoryClothing, children: [
            CategoryNode(name: .defaultCategoryEverydayClothing, children: [
                CategoryNode(name: .defaultCategoryClothingClothesTops),
                CategoryNode(name: .defaultCategoryClothingClothesBottoms),
                CategoryNode(name: .defaultCategoryClothingClothesOuterwear),
                CategoryNode(name: .defaultCategoryClothingClothesUnderwear),
                CategoryNode(name: .defaultCategoryClothingClothesSleepwear),
                CategoryNode(name: .defaultCategoryClothingClothesFormal),
                CategoryNode(name: .defaultCategoryClothingClothesSportswear),
                CategoryNode(name: .defaultCategoryClothingClothesWorkwear)
            ]),
            CategoryNode(name: .defaultCategoryClothingShoes, children: [
                CategoryNode(name: .defaultCategoryClothingShoesCasual),
                CategoryNode(name: .defaultCategoryClothingShoesSports),
                CategoryNode(name: .defaultCategoryClothingShoesFormal),
                CategoryNode(name: .defaultCategoryClothingShoesSlippers)
            ]),
            CategoryNode(name: .defaultCategoryClothingAccessories, children: [
                CategoryNode(name: .defaultCategoryClothingAccessoriesBags),
                CategoryNode(name: .defaultCategoryClothingAccessoriesHats),
                CategoryNode(name: .defaultCategoryClothingAccessoriesBelts),
                CategoryNode(name: .defaultCategoryClothingAccessoriesJewelry),
                CategoryNode(name: .defaultCategoryClothingAccessoriesWatches),
                CategoryNode(name: .defaultCategoryClothingAccessoriesRainwear)
            ]),
            CategoryNode(name: .defaultCategoryEverydayBeauty, children: [
                CategoryNode(name: .defaultCategoryClothingBeautyHaircut),
                CategoryNode(name: .defaultCategoryClothingBeautyHairTreatment),
                CategoryNode(name: .defaultCategoryClothingBeautySkincare),
                CategoryNode(name: .defaultCategoryClothingBeautyCosmetics),
                CategoryNode(name: .defaultCategoryClothingBeautyFragrance),
                CategoryNode(name: .defaultCategoryClothingBeautyNails),
                CategoryNode(name: .defaultCategoryClothingBeautyGrooming)
            ]),
            CategoryNode(name: .defaultCategoryClothingCare, children: [
                CategoryNode(name: .defaultCategoryClothingCareLaundry),
                CategoryNode(name: .defaultCategoryClothingCareDryCleaning),
                CategoryNode(name: .defaultCategoryClothingCareAlterations),
                CategoryNode(name: .defaultCategoryClothingCareShoeRepair),
                CategoryNode(name: .defaultCategoryClothingCareRental)
            ])
        ])

    private static let homeCategories =
        CategoryNode(name: .defaultCategoryHome, children: [
            CategoryNode(name: .defaultCategoryHomeRent),
            CategoryNode(name: .defaultCategoryHomeMortgage, children: [
                CategoryNode(name: .defaultCategoryHomeMortgageInterest),
                CategoryNode(name: .defaultCategoryHomeMortgageFees)
            ]),
            CategoryNode(name: .defaultCategoryHomeFurniture, children: [
                CategoryNode(name: .defaultCategoryHomeFurnitureBed),
                CategoryNode(name: .defaultCategoryHomeFurnitureSeating),
                CategoryNode(name: .defaultCategoryHomeFurnitureStorage),
                CategoryNode(name: .defaultCategoryHomeFurnitureLighting),
                CategoryNode(name: .defaultCategoryHomeFurnitureBedding)
            ]),
            CategoryNode(name: .defaultCategoryHomeUtilities, children: [
                CategoryNode(name: .defaultCategoryHomeUtilitiesWater),
                CategoryNode(name: .defaultCategoryHomeUtilitiesElectricity),
                CategoryNode(name: .defaultCategoryHomeUtilitiesGas),
                CategoryNode(name: .defaultCategoryHomeUtilitiesWaste)
            ]),
            CategoryNode(name: .defaultCategoryHomeTelecom, children: [
                CategoryNode(name: .defaultCategoryHomeTelecomMobile),
                CategoryNode(name: .defaultCategoryHomeTelecomBroadband),
                CategoryNode(name: .defaultCategoryHomeTelecomLandline),
                CategoryNode(name: .defaultCategoryHomeTelecomCable),
                CategoryNode(name: .defaultCategoryHomeTelecomRoaming)
            ]),
            CategoryNode(name: .defaultCategoryHomeHousehold, children: [
                CategoryNode(name: .defaultCategoryHomeHouseholdManagement),
                CategoryNode(name: .defaultCategoryHomeHouseholdSecurity),
                CategoryNode(name: .defaultCategoryHomeHouseholdCleaning),
                CategoryNode(name: .defaultCategoryHomeHouseholdPest),
                CategoryNode(name: .defaultCategoryHomeHouseholdGarden),
                CategoryNode(name: .defaultCategoryHomeHouseholdStorage)
            ]),
            CategoryNode(name: .defaultCategoryHomeAppliances, children: [
                CategoryNode(name: .defaultCategoryHomeAppliancesLarge),
                CategoryNode(name: .defaultCategoryHomeAppliancesClimate),
                CategoryNode(name: .defaultCategoryHomeAppliancesKitchen),
                CategoryNode(name: .defaultCategoryHomeAppliancesCleaning),
                CategoryNode(name: .defaultCategoryHomeAppliancesCookware)
            ]),
            CategoryNode(name: .defaultCategoryHomeRepairs, children: [
                CategoryNode(name: .defaultCategoryHomeRepairsPlumbing),
                CategoryNode(name: .defaultCategoryHomeRepairsLeaks),
                CategoryNode(name: .defaultCategoryHomeRepairsPaint),
                CategoryNode(name: .defaultCategoryHomeRepairsDoors),
                CategoryNode(name: .defaultCategoryHomeRepairsRenovation),
                CategoryNode(name: .defaultCategoryHomeRepairsAppliance),
                CategoryNode(name: .defaultCategoryHomeRepairsMaterials)
            ]),
            CategoryNode(name: .defaultCategoryHomeMoving, children: [
                CategoryNode(name: .defaultCategoryHomeMovingMovers),
                CategoryNode(name: .defaultCategoryHomeMovingAgency),
                CategoryNode(name: .defaultCategoryHomeMovingInstallation)
            ]),
            CategoryNode(name: .defaultCategoryHomeInsurance, children: [
                CategoryNode(name: .defaultCategoryHomeInsuranceFire),
                CategoryNode(name: .defaultCategoryHomeInsuranceEarthquake),
                CategoryNode(name: .defaultCategoryHomeInsuranceContents)
            ])
        ])

    private static let transportCategories =
        CategoryNode(name: .defaultCategoryTransport, children: [
            CategoryNode(name: .defaultCategoryTransportPublic, children: [
                CategoryNode(name: .defaultCategoryTransportBus),
                CategoryNode(name: .defaultCategoryTransportMetro),
                CategoryNode(name: .defaultCategoryTransportTrain),
                CategoryNode(name: .defaultCategoryTransportPublicCoach),
                CategoryNode(name: .defaultCategoryTransportPublicFerry),
                CategoryNode(name: .defaultCategoryTransportPublicPass)
            ]),
            CategoryNode(name: .defaultCategoryTransportTaxi),
            CategoryNode(name: .defaultCategoryTransportCycling, children: [
                CategoryNode(name: .defaultCategoryTransportCyclingPurchase),
                CategoryNode(name: .defaultCategoryTransportCyclingShared),
                CategoryNode(name: .defaultCategoryTransportCyclingRepairs),
                CategoryNode(name: .defaultCategoryTransportCyclingAccessories)
            ]),
            CategoryNode(name: .defaultCategoryTransportScooter, children: [
                CategoryNode(name: .defaultCategoryTransportScooterFuel),
                CategoryNode(name: .defaultCategoryTransportScooterBattery),
                CategoryNode(name: .defaultCategoryTransportScooterParking),
                CategoryNode(name: .defaultCategoryTransportScooterService),
                CategoryNode(name: .defaultCategoryTransportScooterTires),
                CategoryNode(name: .defaultCategoryTransportScooterInsurance),
                CategoryNode(name: .defaultCategoryTransportScooterHelmet),
                CategoryNode(name: .defaultCategoryTransportScooterPurchase),
                CategoryNode(name: .defaultCategoryTransportScooterRental)
            ]),
            CategoryNode(name: .defaultCategoryTransportCar, children: [
                CategoryNode(name: .defaultCategoryTransportFuel, children: [
                    CategoryNode(name: .defaultCategoryTransportCarFuelPetrol),
                    CategoryNode(name: .defaultCategoryTransportCarFuelDiesel),
                    CategoryNode(name: .defaultCategoryTransportCarFuelCharging)
                ]),
                CategoryNode(name: .defaultCategoryTransportParking),
                CategoryNode(name: .defaultCategoryTransportTolls),
                CategoryNode(name: .defaultCategoryTransportMaintenance, children: [
                    CategoryNode(name: .defaultCategoryTransportCarMaintenanceOil),
                    CategoryNode(name: .defaultCategoryTransportCarMaintenanceFilters),
                    CategoryNode(name: .defaultCategoryTransportCarMaintenanceBrakes),
                    CategoryNode(name: .defaultCategoryTransportCarMaintenanceBattery),
                    CategoryNode(name: .defaultCategoryTransportCarMaintenanceAirConditioning),
                    CategoryNode(name: .defaultCategoryTransportCarMaintenanceInspection)
                ]),
                CategoryNode(name: .defaultCategoryTransportCarWash, children: [
                    CategoryNode(name: .defaultCategoryTransportCarWashSelf),
                    CategoryNode(name: .defaultCategoryTransportCarWashService),
                    CategoryNode(name: .defaultCategoryTransportCarWashDetailing)
                ]),
                CategoryNode(name: .defaultCategoryTransportTires, children: [
                    CategoryNode(name: .defaultCategoryTransportCarTiresReplacement),
                    CategoryNode(name: .defaultCategoryTransportCarTiresAlignment),
                    CategoryNode(name: .defaultCategoryTransportCarTiresRepair)
                ]),
                CategoryNode(name: .defaultCategoryTransportCarRepairs),
                CategoryNode(name: .defaultCategoryTransportCarInsurance, children: [
                    CategoryNode(name: .defaultCategoryTransportCarInsuranceCompulsory),
                    CategoryNode(name: .defaultCategoryTransportCarInsuranceLiability),
                    CategoryNode(name: .defaultCategoryTransportCarInsuranceDamage)
                ]),
                CategoryNode(name: .defaultCategoryTransportCarAccessories),
                CategoryNode(name: .defaultCategoryTransportCarPurchase),
                CategoryNode(name: .defaultCategoryTransportCarRental),
                CategoryNode(name: .defaultCategoryTransportCarInspectionFee),
                CategoryNode(name: .defaultCategoryTransportCarRoadside)
            ]),
            CategoryNode(name: .defaultCategoryTransportAir, children: [
                CategoryNode(name: .defaultCategoryTransportAirTicket),
                CategoryNode(name: .defaultCategoryTransportAirBaggage),
                CategoryNode(name: .defaultCategoryTransportAirTransfer)
            ]),
            CategoryNode(name: .defaultCategoryTransportDrivingLessons)
        ])

    private static let educationCategories =
        CategoryNode(name: .defaultCategoryEducation, children: [
            CategoryNode(name: .defaultCategoryEducationTuition, children: [
                CategoryNode(name: .defaultCategoryEducationTuitionSchool),
                CategoryNode(name: .defaultCategoryEducationTuitionFees),
                CategoryNode(name: .defaultCategoryEducationTuitionDormitory)
            ]),
            CategoryNode(name: .defaultCategoryEducationTutoring, children: [
                CategoryNode(name: .defaultCategoryEducationTutoringCramSchool),
                CategoryNode(name: .defaultCategoryEducationTutoringPrivate),
                CategoryNode(name: .defaultCategoryEducationTutoringAfterSchool)
            ]),
            CategoryNode(name: .defaultCategoryEducationBooks, children: [
                CategoryNode(name: .defaultCategoryEducationBooksTextbooks),
                CategoryNode(name: .defaultCategoryEducationBooksReading),
                CategoryNode(name: .defaultCategoryEducationBooksDigital)
            ]),
            CategoryNode(name: .defaultCategoryEducationSkills, children: [
                CategoryNode(name: .defaultCategoryEducationSkillsLanguage),
                CategoryNode(name: .defaultCategoryEducationSkillsProfessional),
                CategoryNode(name: .defaultCategoryEducationSkillsArts),
                CategoryNode(name: .defaultCategoryEducationSkillsOnline),
                CategoryNode(name: .defaultCategoryEducationSkillsWorkshops)
            ]),
            CategoryNode(name: .defaultCategoryEducationSupplies, children: [
                CategoryNode(name: .defaultCategoryEducationSuppliesStationery),
                CategoryNode(name: .defaultCategoryEducationSuppliesPrinting),
                CategoryNode(name: .defaultCategoryEducationSuppliesMaterials)
            ]),
            CategoryNode(name: .defaultCategoryEducationExams, children: [
                CategoryNode(name: .defaultCategoryEducationExamsRegistration),
                CategoryNode(name: .defaultCategoryEducationExamsCertification)
            ]),
            CategoryNode(name: .defaultCategoryEducationActivities, children: [
                CategoryNode(name: .defaultCategoryEducationActivitiesTrips),
                CategoryNode(name: .defaultCategoryEducationActivitiesClubs),
                CategoryNode(name: .defaultCategoryEducationActivitiesTransport)
            ])
        ])

    private static let leisureCategories =
        CategoryNode(name: .defaultCategoryLeisure, children: [
            CategoryNode(name: .defaultCategoryLeisureMovies),
            CategoryNode(name: .defaultCategoryLeisureTravel, children: [
                CategoryNode(name: .defaultCategoryLeisureTravelLodging),
                CategoryNode(name: .defaultCategoryLeisureTravelTours),
                CategoryNode(name: .defaultCategoryLeisureTravelAttractions),
                CategoryNode(name: .defaultCategoryLeisureTravelVisa),
                CategoryNode(name: .defaultCategoryLeisureTravelLuggage),
                CategoryNode(name: .defaultCategoryLeisureTravelInsurance),
                CategoryNode(name: .defaultCategoryLeisureTravelSouvenirs)
            ]),
            CategoryNode(name: .defaultCategoryLeisureSports, children: [
                CategoryNode(name: .defaultCategoryLeisureSportsGym),
                CategoryNode(name: .defaultCategoryLeisureSportsVenue),
                CategoryNode(name: .defaultCategoryLeisureSportsCoaching),
                CategoryNode(name: .defaultCategoryLeisureSportsEquipment),
                CategoryNode(name: .defaultCategoryLeisureSportsEvents)
            ]),
            CategoryNode(name: .defaultCategoryLeisureGames, children: [
                CategoryNode(name: .defaultCategoryLeisureGamesPurchase),
                CategoryNode(name: .defaultCategoryLeisureGamesInApp),
                CategoryNode(name: .defaultCategoryLeisureGamesConsole),
                CategoryNode(name: .defaultCategoryLeisureGamesBoard)
            ]),
            CategoryNode(name: .defaultCategoryLeisureSubscriptions, children: [
                CategoryNode(name: .defaultCategoryLeisureSubscriptionsVideo),
                CategoryNode(name: .defaultCategoryLeisureSubscriptionsMusic),
                CategoryNode(name: .defaultCategoryLeisureSubscriptionsGaming),
                CategoryNode(name: .defaultCategoryLeisureSubscriptionsMedia)
            ]),
            CategoryNode(name: .defaultCategoryLeisureActivities, children: [
                CategoryNode(name: .defaultCategoryLeisureActivitiesPerformances),
                CategoryNode(name: .defaultCategoryLeisureActivitiesMuseums),
                CategoryNode(name: .defaultCategoryLeisureActivitiesKaraoke),
                CategoryNode(name: .defaultCategoryLeisureActivitiesParks),
                CategoryNode(name: .defaultCategoryLeisureActivitiesSpa)
            ]),
            CategoryNode(name: .defaultCategoryLeisureHobbies, children: [
                CategoryNode(name: .defaultCategoryLeisureHobbiesCamping),
                CategoryNode(name: .defaultCategoryLeisureHobbiesPhotography),
                CategoryNode(name: .defaultCategoryLeisureHobbiesCrafts),
                CategoryNode(name: .defaultCategoryLeisureHobbiesMusic),
                CategoryNode(name: .defaultCategoryLeisureHobbiesCollections),
                CategoryNode(name: .defaultCategoryLeisureHobbiesPlants)
            ])
        ])

    private static let dailyCategories =
        CategoryNode(name: .defaultCategoryDaily, children: [
            CategoryNode(name: .defaultCategoryDailyPersonal, children: [
                CategoryNode(name: .defaultCategoryDailyPersonalHair),
                CategoryNode(name: .defaultCategoryDailyPersonalDental),
                CategoryNode(name: .defaultCategoryDailyPersonalShaving),
                CategoryNode(name: .defaultCategoryDailyPersonalMenstrual),
                CategoryNode(name: .defaultCategoryDailyPersonalTissues)
            ]),
            CategoryNode(name: .defaultCategoryDailyCleaning, children: [
                CategoryNode(name: .defaultCategoryDailyCleaningLaundry),
                CategoryNode(name: .defaultCategoryDailyCleaningDishes),
                CategoryNode(name: .defaultCategoryDailyCleaningBathroom),
                CategoryNode(name: .defaultCategoryDailyCleaningTools),
                CategoryNode(name: .defaultCategoryDailyCleaningBags)
            ]),
            CategoryNode(name: .defaultCategoryDailyKitchen, children: [
                CategoryNode(name: .defaultCategoryDailyKitchenWraps),
                CategoryNode(name: .defaultCategoryDailyKitchenFilters),
                CategoryNode(name: .defaultCategoryDailyKitchenBatteries),
                CategoryNode(name: .defaultCategoryDailyKitchenStorage)
            ]),
            CategoryNode(name: .defaultCategoryDailyServices, children: [
                CategoryNode(name: .defaultCategoryDailyServicesPostage),
                CategoryNode(name: .defaultCategoryDailyServicesMembership),
                CategoryNode(name: .defaultCategoryDailyServicesKeys),
                CategoryNode(name: .defaultCategoryDailyServicesUmbrella)
            ])
        ])

    private static let digitalCategories =
        CategoryNode(name: .defaultCategoryDigital, children: [
            CategoryNode(name: .defaultCategoryDigitalDevices, children: [
                CategoryNode(name: .defaultCategoryDigitalDevicesPhone),
                CategoryNode(name: .defaultCategoryDigitalDevicesComputer),
                CategoryNode(name: .defaultCategoryDigitalDevicesPeripherals),
                CategoryNode(name: .defaultCategoryDigitalDevicesAudio),
                CategoryNode(name: .defaultCategoryDigitalDevicesRepairs)
            ]),
            CategoryNode(name: .defaultCategoryDigitalSoftware, children: [
                CategoryNode(name: .defaultCategoryDigitalSoftwareApps),
                CategoryNode(name: .defaultCategoryDigitalSoftwareProductivity),
                CategoryNode(name: .defaultCategoryDigitalSoftwareCloud),
                CategoryNode(name: .defaultCategoryDigitalSoftwareAi),
                CategoryNode(name: .defaultCategoryDigitalSoftwareSecurity),
                CategoryNode(name: .defaultCategoryDigitalSoftwareHosting)
            ]),
            CategoryNode(name: .defaultCategoryDigitalWork, children: [
                CategoryNode(name: .defaultCategoryDigitalWorkWorkspace),
                CategoryNode(name: .defaultCategoryDigitalWorkSupplies),
                CategoryNode(name: .defaultCategoryDigitalWorkTools),
                CategoryNode(name: .defaultCategoryDigitalWorkDues),
                CategoryNode(name: .defaultCategoryDigitalWorkPlatform)
            ])
        ])

    private static let healthCategories =
        CategoryNode(name: .defaultCategoryHealth, children: [
            CategoryNode(name: .defaultCategoryHealthMedicine, children: [
                CategoryNode(name: .defaultCategoryHealthMedicineClinic),
                CategoryNode(name: .defaultCategoryHealthMedicineEmergency),
                CategoryNode(name: .defaultCategoryHealthMedicinePrescriptions),
                CategoryNode(name: .defaultCategoryHealthMedicinePharmacy),
                CategoryNode(name: .defaultCategoryHealthMedicineTraditional)
            ]),
            CategoryNode(name: .defaultCategoryHealthInsurance, children: [
                CategoryNode(name: .defaultCategoryHealthInsuranceMedical),
                CategoryNode(name: .defaultCategoryHealthInsuranceLife),
                CategoryNode(name: .defaultCategoryHealthInsuranceAccident),
                CategoryNode(name: .defaultCategoryHealthInsuranceCancer),
                CategoryNode(name: .defaultCategoryHealthInsuranceDisability)
            ]),
            CategoryNode(name: .defaultCategoryHealthDental, children: [
                CategoryNode(name: .defaultCategoryHealthDentalTreatment),
                CategoryNode(name: .defaultCategoryHealthDentalOrthodontics),
                CategoryNode(name: .defaultCategoryHealthDentalImplants)
            ]),
            CategoryNode(name: .defaultCategoryHealthVision, children: [
                CategoryNode(name: .defaultCategoryHealthVisionGlasses),
                CategoryNode(name: .defaultCategoryHealthVisionContacts),
                CategoryNode(name: .defaultCategoryHealthVisionHearing)
            ]),
            CategoryNode(name: .defaultCategoryHealthHospital, children: [
                CategoryNode(name: .defaultCategoryHealthHospitalRoom),
                CategoryNode(name: .defaultCategoryHealthHospitalSurgery),
                CategoryNode(name: .defaultCategoryHealthHospitalMaterials)
            ]),
            CategoryNode(name: .defaultCategoryHealthPrevention, children: [
                CategoryNode(name: .defaultCategoryHealthPreventionCheckup),
                CategoryNode(name: .defaultCategoryHealthPreventionVaccine),
                CategoryNode(name: .defaultCategoryHealthPreventionNutrition)
            ]),
            CategoryNode(name: .defaultCategoryHealthTherapy, children: [
                CategoryNode(name: .defaultCategoryHealthTherapyRehab),
                CategoryNode(name: .defaultCategoryHealthTherapyCounseling),
                CategoryNode(name: .defaultCategoryHealthTherapyEquipment)
            ])
        ])

    private static let socialInsuranceCategories =
        CategoryNode(name: .defaultCategorySocialInsurance, children: [
            CategoryNode(name: .defaultCategorySocialInsuranceNhi, children: [
                CategoryNode(name: .defaultCategorySocialInsuranceNhiPremium),
                CategoryNode(name: .defaultCategorySocialInsuranceNhiSupplementary)
            ]),
            CategoryNode(name: .defaultCategorySocialInsuranceLabor),
            CategoryNode(name: .defaultCategorySocialInsurancePension),
            CategoryNode(name: .defaultCategorySocialInsuranceAgricultural),
            CategoryNode(name: .defaultCategorySocialInsuranceUnion)
        ])

    private static let childcareCategories =
        CategoryNode(name: .defaultCategoryChildcare, children: [
            CategoryNode(name: .defaultCategoryChildcarePregnancy, children: [
                CategoryNode(name: .defaultCategoryChildcarePregnancyCheckups),
                CategoryNode(name: .defaultCategoryChildcarePregnancyBirth),
                CategoryNode(name: .defaultCategoryChildcarePregnancyPostpartum),
                CategoryNode(name: .defaultCategoryChildcarePregnancySupplies)
            ]),
            CategoryNode(name: .defaultCategoryChildcareFeeding, children: [
                CategoryNode(name: .defaultCategoryChildcareFeedingFormula),
                CategoryNode(name: .defaultCategoryChildcareFeedingFood),
                CategoryNode(name: .defaultCategoryChildcareFeedingBottles)
            ]),
            CategoryNode(name: .defaultCategoryChildcareSupplies, children: [
                CategoryNode(name: .defaultCategoryChildcareSuppliesDiapers),
                CategoryNode(name: .defaultCategoryChildcareSuppliesClothes),
                CategoryNode(name: .defaultCategoryChildcareSuppliesStroller),
                CategoryNode(name: .defaultCategoryChildcareSuppliesFurniture),
                CategoryNode(name: .defaultCategoryChildcareSuppliesToys)
            ]),
            CategoryNode(name: .defaultCategoryChildcareCare, children: [
                CategoryNode(name: .defaultCategoryChildcareCareNanny),
                CategoryNode(name: .defaultCategoryChildcareCareNursery),
                CategoryNode(name: .defaultCategoryChildcareCareKindergarten),
                CategoryNode(name: .defaultCategoryChildcareCareTemporary)
            ]),
            CategoryNode(name: .defaultCategoryChildcareActivities)
        ])

    private static let careCategories =
        CategoryNode(name: .defaultCategoryCare, children: [
            CategoryNode(name: .defaultCategoryCareServices, children: [
                CategoryNode(name: .defaultCategoryCareServicesHome),
                CategoryNode(name: .defaultCategoryCareServicesDay),
                CategoryNode(name: .defaultCategoryCareServicesResidential),
                CategoryNode(name: .defaultCategoryCareServicesRespite),
                CategoryNode(name: .defaultCategoryCareServicesCarer),
                CategoryNode(name: .defaultCategoryCareServicesAgency)
            ]),
            CategoryNode(name: .defaultCategoryCareSupplies, children: [
                CategoryNode(name: .defaultCategoryCareSuppliesAids),
                CategoryNode(name: .defaultCategoryCareSuppliesConsumables),
                CategoryNode(name: .defaultCategoryCareSuppliesRental)
            ]),
            CategoryNode(name: .defaultCategoryCareAccessibility),
            CategoryNode(name: .defaultCategoryCareTransport)
        ])

    private static let petsCategories =
        CategoryNode(name: .defaultCategoryPets, children: [
            CategoryNode(name: .defaultCategoryPetsFood, children: [
                CategoryNode(name: .defaultCategoryPetsFoodFeed),
                CategoryNode(name: .defaultCategoryPetsFoodWet),
                CategoryNode(name: .defaultCategoryPetsFoodTreats)
            ]),
            CategoryNode(name: .defaultCategoryPetsSupplies, children: [
                CategoryNode(name: .defaultCategoryPetsSuppliesLitter),
                CategoryNode(name: .defaultCategoryPetsSuppliesEquipment),
                CategoryNode(name: .defaultCategoryPetsSuppliesToys)
            ]),
            CategoryNode(name: .defaultCategoryPetsHealth, children: [
                CategoryNode(name: .defaultCategoryPetsHealthClinic),
                CategoryNode(name: .defaultCategoryPetsHealthVaccines),
                CategoryNode(name: .defaultCategoryPetsHealthSurgery),
                CategoryNode(name: .defaultCategoryPetsHealthMedicine),
                CategoryNode(name: .defaultCategoryPetsHealthInsurance)
            ]),
            CategoryNode(name: .defaultCategoryPetsServices, children: [
                CategoryNode(name: .defaultCategoryPetsServicesGrooming),
                CategoryNode(name: .defaultCategoryPetsServicesBoarding),
                CategoryNode(name: .defaultCategoryPetsServicesTraining),
                CategoryNode(name: .defaultCategoryPetsServicesRegistration),
                CategoryNode(name: .defaultCategoryPetsServicesFuneral)
            ])
        ])

    private static let giftsCategories =
        CategoryNode(name: .defaultCategoryGifts, children: [
            CategoryNode(name: .defaultCategoryGiftsOccasions, children: [
                CategoryNode(name: .defaultCategoryGiftsOccasionsWedding),
                CategoryNode(name: .defaultCategoryGiftsOccasionsNewYear),
                CategoryNode(name: .defaultCategoryGiftsOccasionsBirthday),
                CategoryNode(name: .defaultCategoryGiftsOccasionsBirth),
                CategoryNode(name: .defaultCategoryGiftsOccasionsFuneral),
                CategoryNode(name: .defaultCategoryGiftsOccasionsFestivals)
            ]),
            CategoryNode(name: .defaultCategoryGiftsSupport, children: [
                CategoryNode(name: .defaultCategoryGiftsSupportParents),
                CategoryNode(name: .defaultCategoryGiftsSupportAllowance),
                CategoryNode(name: .defaultCategoryGiftsSupportMaintenance)
            ]),
            CategoryNode(name: .defaultCategoryGiftsDonations, children: [
                CategoryNode(name: .defaultCategoryGiftsDonationsCharity),
                CategoryNode(name: .defaultCategoryGiftsDonationsReligious),
                CategoryNode(name: .defaultCategoryGiftsDonationsVolunteering)
            ]),
            CategoryNode(name: .defaultCategoryGiftsEvents, children: [
                CategoryNode(name: .defaultCategoryGiftsEventsWeddingServices),
                CategoryNode(name: .defaultCategoryGiftsEventsFuneralServices)
            ])
        ])

    private static let taxCategories =
        CategoryNode(name: .defaultCategoryTax, children: [
            CategoryNode(name: .defaultCategoryTaxIncome, children: [
                CategoryNode(name: .defaultCategoryTaxIncomeIndividual),
                CategoryNode(name: .defaultCategoryTaxIncomePropertySale),
                CategoryNode(name: .defaultCategoryTaxIncomeOverseas)
            ]),
            CategoryNode(name: .defaultCategoryTaxProperty, children: [
                CategoryNode(name: .defaultCategoryTaxPropertyHouse),
                CategoryNode(name: .defaultCategoryTaxPropertyLand),
                CategoryNode(name: .defaultCategoryTaxPropertyIncrement),
                CategoryNode(name: .defaultCategoryTaxPropertyDeed)
            ]),
            CategoryNode(name: .defaultCategoryTaxVehicle, children: [
                CategoryNode(name: .defaultCategoryTaxVehicleLicense),
                CategoryNode(name: .defaultCategoryTaxVehicleRoadMaintenance)
            ]),
            CategoryNode(name: .defaultCategoryTaxTransfers, children: [
                CategoryNode(name: .defaultCategoryTaxTransfersEstate),
                CategoryNode(name: .defaultCategoryTaxTransfersGift)
            ]),
            CategoryNode(name: .defaultCategoryTaxTransactions, children: [
                CategoryNode(name: .defaultCategoryTaxTransactionsStamp),
                CategoryNode(name: .defaultCategoryTaxTransactionsSecurities),
                CategoryNode(name: .defaultCategoryTaxTransactionsFutures),
                CategoryNode(name: .defaultCategoryTaxTransactionsCustoms),
                CategoryNode(name: .defaultCategoryTaxTransactionsBusiness),
                CategoryNode(name: .defaultCategoryTaxTransactionsOther)
            ]),
            CategoryNode(name: .defaultCategoryTaxPublicFees, children: [
                CategoryNode(name: .defaultCategoryTaxPublicFeesPassport),
                CategoryNode(name: .defaultCategoryTaxPublicFeesDocuments),
                CategoryNode(name: .defaultCategoryTaxPublicFeesRegistration),
                CategoryNode(name: .defaultCategoryTaxPublicFeesNotary),
                CategoryNode(name: .defaultCategoryTaxPublicFeesLicense)
            ]),
            CategoryNode(name: .defaultCategoryTaxPenalties, children: [
                CategoryNode(name: .defaultCategoryTaxPenaltiesTraffic),
                CategoryNode(name: .defaultCategoryTaxPenaltiesTax),
                CategoryNode(name: .defaultCategoryTaxPenaltiesOther)
            ])
        ])

    private static let financeCategories =
        CategoryNode(name: .defaultCategoryFinance, children: [
            CategoryNode(name: .defaultCategoryFinanceBank, children: [
                CategoryNode(name: .defaultCategoryFinanceBankTransfer),
                CategoryNode(name: .defaultCategoryFinanceBankWithdrawal),
                CategoryNode(name: .defaultCategoryFinanceBankRemittance),
                CategoryNode(name: .defaultCategoryFinanceBankExchange)
            ]),
            CategoryNode(name: .defaultCategoryFinanceCard, children: [
                CategoryNode(name: .defaultCategoryFinanceCardAnnual),
                CategoryNode(name: .defaultCategoryFinanceCardInterest),
                CategoryNode(name: .defaultCategoryFinanceCardInstallment),
                CategoryNode(name: .defaultCategoryFinanceCardForeign),
                CategoryNode(name: .defaultCategoryFinanceCardLate)
            ]),
            CategoryNode(name: .defaultCategoryFinanceLoan, children: [
                CategoryNode(name: .defaultCategoryFinanceLoanInterest),
                CategoryNode(name: .defaultCategoryFinanceLoanSetup)
            ]),
            CategoryNode(name: .defaultCategoryFinanceInvestment, children: [
                CategoryNode(name: .defaultCategoryFinanceInvestmentBrokerage),
                CategoryNode(name: .defaultCategoryFinanceInvestmentManagement),
                CategoryNode(name: .defaultCategoryFinanceInvestmentCustody)
            ]),
            CategoryNode(name: .defaultCategoryFinanceProfessional, children: [
                CategoryNode(name: .defaultCategoryFinanceProfessionalAccountant),
                CategoryNode(name: .defaultCategoryFinanceProfessionalLegal)
            ])
        ])

    private static let incomeCategories =
        CategoryNode(name: .defaultCategoryIncome, children: [
            CategoryNode(name: .defaultCategoryIncomeSalary),
            CategoryNode(name: .defaultCategoryIncomeBonus),
            CategoryNode(name: .defaultCategoryIncomeOther),
            CategoryNode(name: .defaultCategoryIncomeFreelance),
            CategoryNode(name: .defaultCategoryIncomeBusiness),
            CategoryNode(name: .defaultCategoryIncomeInterest),
            CategoryNode(name: .defaultCategoryIncomeDividends),
            CategoryNode(name: .defaultCategoryIncomeRent),
            CategoryNode(name: .defaultCategoryIncomeBenefits),
            CategoryNode(name: .defaultCategoryIncomePension),
            CategoryNode(name: .defaultCategoryIncomeGifts),
            CategoryNode(name: .defaultCategoryIncomePrizes)
        ])

    private static let otherCategories =
        CategoryNode(name: .defaultCategoryOther, children: [
            CategoryNode(name: .defaultCategoryOtherUnclassified),
            CategoryNode(name: .defaultCategoryOtherEmergency),
            CategoryNode(name: .defaultCategoryOtherLoss)
        ])

}
