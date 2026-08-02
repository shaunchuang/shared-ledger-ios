import Foundation

/// App 內所有使用者可見文字的鍵。
///
/// 這個列舉就是 `Localizable.xcstrings` 的索引：新增文案必須同時加一個 case 與一筆
/// catalog 條目，`LocalizationTests` 會比對兩邊的鍵集合，任何一邊漏掉都會讓測試失敗。
/// 用列舉而不是字串常數，是為了讓 `Text(.settingsTitle)` 這種寫法在編譯期就擋掉拼錯的鍵，
/// 而 `CaseIterable` 讓完整性測試不需要另外維護一份清單。
enum LedgerStringKey: String, CaseIterable, Sendable {
    // MARK: - 帳戶種類
    case accountTypeBank = "accountType.bank"
    case accountTypeCash = "accountType.cash"
    case accountTypeCreditCard = "accountType.creditCard"
    case accountTypeOther = "accountType.other"

    // MARK: - 貨幣
    case currencyDisplayNameFormat = "currency.displayName.format"

    // MARK: - 交易種類
    case entryKindBalanceAdjustment = "entryKind.balanceAdjustment"
    case entryKindExpense = "entryKind.expense"
    case entryKindIncome = "entryKind.income"
    case entryKindTransfer = "entryKind.transfer"

    // MARK: - 成員角色
    case memberRoleAdministrator = "memberRole.administrator"
    case memberRoleMember = "memberRole.member"
    case memberRoleOwner = "memberRole.owner"
    case memberRoleViewer = "memberRole.viewer"

    // MARK: - 通知
    case notificationAuthorizationAuthorizedDetail = "notification.authorization.authorized.detail"
    case notificationAuthorizationAuthorizedTitle = "notification.authorization.authorized.title"
    case notificationAuthorizationDeniedDetail = "notification.authorization.denied.detail"
    case notificationAuthorizationDeniedTitle = "notification.authorization.denied.title"
    case notificationAuthorizationNotDeterminedDetail = "notification.authorization.notDetermined.detail"
    case notificationAuthorizationNotDeterminedTitle = "notification.authorization.notDetermined.title"
    case notificationAuthorizationProvisionalDetail = "notification.authorization.provisional.detail"
    case notificationAuthorizationProvisionalTitle = "notification.authorization.provisional.title"
    case notificationAuthorizationUnavailableDetail = "notification.authorization.unavailable.detail"
    case notificationAuthorizationUnavailableTitle = "notification.authorization.unavailable.title"
    case notificationBodyGroupOwnershipTransferred = "notification.body.group.ownershipTransferred"
    case notificationBodyMemberIdentityConfirmed = "notification.body.member.identityConfirmed"
    case notificationBodyMemberInvitationResent = "notification.body.member.invitationResent"
    case notificationBodyMemberInvitationRevoked = "notification.body.member.invitationRevoked"
    case notificationBodyMemberLeft = "notification.body.member.left"
    case notificationBodyMemberRemoved = "notification.body.member.removed"
    case notificationBodySettlementRecorded = "notification.body.settlement.recorded"
    case notificationBodySettlementReversed = "notification.body.settlement.reversed"
    case notificationBodySettlementReminderBoth = "notification.body.settlementReminder.both"
    case notificationBodySettlementReminderOwed = "notification.body.settlementReminder.owed"
    case notificationBodySettlementReminderOwes = "notification.body.settlementReminder.owes"
    case notificationBodyTransactionCreated = "notification.body.transaction.created"
    case notificationBodyTransactionUpdated = "notification.body.transaction.updated"
    case notificationBodyTransactionVoided = "notification.body.transaction.voided"
    case notificationCategoryGroupInvitationDetail = "notification.category.groupInvitation.detail"
    case notificationCategoryGroupInvitationTitle = "notification.category.groupInvitation.title"
    case notificationCategorySettlementReminderDetail = "notification.category.settlementReminder.detail"
    case notificationCategorySettlementReminderTitle = "notification.category.settlementReminder.title"
    case notificationCategoryTransactionChangeDetail = "notification.category.transactionChange.detail"
    case notificationCategoryTransactionChangeTitle = "notification.category.transactionChange.title"
    case notificationRowAccessibilityLabel = "notification.row.accessibilityLabel"
    case notificationRowSummaryAllOff = "notification.row.summary.allOff"
    case notificationRowSummaryAllOn = "notification.row.summary.allOn"
    case notificationRowSummaryPartial = "notification.row.summary.partial"
    case notificationSettingsAppUsableFooter = "notification.settings.appUsable.footer"
    case notificationSettingsAppUsableTitle = "notification.settings.appUsable.title"
    case notificationSettingsCategoriesFooterAllDisabled = "notification.settings.categories.footer.allDisabled"
    case notificationSettingsCategoriesFooterNormal = "notification.settings.categories.footer.normal"
    case notificationSettingsCategoriesFooterNotAllowed = "notification.settings.categories.footer.notAllowed"
    case notificationSettingsCategoriesHeader = "notification.settings.categories.header"
    case notificationSettingsEnable = "notification.settings.enable"
    case notificationSettingsOpenSystemSettings = "notification.settings.openSystemSettings"
    case notificationTitle = "notification.title"

    // MARK: - 報表範圍
    case reportScopeAllActiveBooks = "reportScope.allActiveBooks"
    case reportScopeCurrentBook = "reportScope.currentBook"
    case reportScopeSelectedBookIDs = "reportScope.selectedBookIDs"

    // MARK: - 設定
    case settingsProfileSubtitle = "settings.profile.subtitle"
    case settingsRowAppearanceDetail = "settings.row.appearance.detail"
    case settingsRowAppearanceTitle = "settings.row.appearance.title"
    case settingsRowDeleteDetail = "settings.row.delete.detail"
    case settingsRowDeleteTitle = "settings.row.delete.title"
    case settingsRowExportDetail = "settings.row.export.detail"
    case settingsRowExportTitle = "settings.row.export.title"
    case settingsRowGroupManagementDetail = "settings.row.groupManagement.detail"
    case settingsRowGroupManagementTitle = "settings.row.groupManagement.title"
    case settingsSectionData = "settings.section.data"
    case settingsSectionPreferences = "settings.section.preferences"
    case settingsSectionSharedLedger = "settings.section.sharedLedger"
    case settingsSectionSync = "settings.section.sync"
    case settingsTitle = "settings.title"
    case settingsVersion = "settings.version"

    // MARK: - iCloud 同步
    case syncErrorNetwork = "sync.error.network"
    case syncErrorNotAuthenticated = "sync.error.notAuthenticated"
    case syncErrorPermission = "sync.error.permission"
    case syncErrorQuotaExceeded = "sync.error.quotaExceeded"
    case syncErrorServiceBusy = "sync.error.serviceBusy"
    case syncRowAccessibilityLabel = "sync.row.accessibilityLabel"
    case syncStateFailedDetail = "sync.state.failed.detail"
    case syncStateFailedTitle = "sync.state.failed.title"
    case syncStateOfflineDetail = "sync.state.offline.detail"
    case syncStateOfflineTitle = "sync.state.offline.title"
    case syncStateRestrictedDetail = "sync.state.restricted.detail"
    case syncStateRestrictedTitle = "sync.state.restricted.title"
    case syncStateSignedOutDetail = "sync.state.signedOut.detail"
    case syncStateSignedOutTitle = "sync.state.signedOut.title"
    case syncStateSyncingDetail = "sync.state.syncing.detail"
    case syncStateSyncingTitle = "sync.state.syncing.title"
    case syncStateUndeterminedDetail = "sync.state.undetermined.detail"
    case syncStateUndeterminedTitle = "sync.state.undetermined.title"
    case syncStateUpToDateDetail = "sync.state.upToDate.detail"
    case syncStateUpToDateDetailLastSync = "sync.state.upToDate.detail.lastSync"
    case syncStateUpToDateTitle = "sync.state.upToDate.title"
    case syncTitle = "sync.title"
    case syncViewInProgress = "sync.view.inProgress"
    case syncViewLocalDataFooter = "sync.view.localData.footer"
    case syncViewLocalDataTitle = "sync.view.localData.title"
    case syncViewRecheck = "sync.view.recheck"
    case syncViewRecheckFooter = "sync.view.recheck.footer"

    // MARK: - 分頁
    case tabCategories = "tab.categories"
    case tabOverview = "tab.overview"
    case tabSettings = "tab.settings"
    case tabSettlement = "tab.settlement"
    case tabTransactions = "tab.transactions"
}
