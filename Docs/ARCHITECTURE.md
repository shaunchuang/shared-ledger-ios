# 架構說明

> 本文件是 Shared Ledger 技術基線、專案設定、資料模型、同步、Concurrency、隱私與建置驗證的唯一來源。產品範圍與優先順序請參考 [MVP 產品規格](MVP.md)。

## 技術基線

- Swift 5.9 或更新版本。
- SwiftUI，最低支援 iOS 17。
- Core Data + `NSPersistentCloudKitContainer`。
- private 與 shared 兩個 persistent store。
- CloudKit Sharing + `UICloudSharingController`。
- ContactsUI 系統聯絡人選擇器。
- XCTest 與 GitHub Actions `xcodebuild build-for-testing`。

## Xcode 專案管理

專案直接維護並提交 `SharedLedger.xcodeproj`，不使用 XcodeGen。`SharedLedger.xcodeproj/project.pbxproj` 是目前 project 設定來源。

新增、刪除或移動檔案，或修改 target、Info.plist、capability、build setting 時，使用 Xcode 更新 project，並檢查 diff 沒有遺失 target membership、build phase 或 capability。除非明確決定遷移專案管理方式，否則不得重新引入 `project.yml` 或 XcodeGen。

## 固定識別與能力

| 項目 | 值 |
| --- | --- |
| App target | `SharedLedger` |
| Test target | `SharedLedgerTests` |
| Bundle identifier | `com.shaunchuang.SharedLedger` |
| CloudKit container | `iCloud.com.shaunchuang.SharedLedger` |
| CloudKit capability | 啟用 |
| Push Notifications | 啟用 |
| Background Modes | 包含 `remote-notification` |

Debug／Release build settings 都必須保留：

```text
INFOPLIST_KEY_UIBackgroundModes = "remote-notification";
```

Apple Developer Team 屬於 signing 設定，不可在不知道完整 Team ID 時猜測或任意改寫。

## 模組方向

- `App`：生命週期、依賴組裝及根導航。
- `DesignSystem`：色彩、卡片、按鈕、徽章、頭像與共用視覺元件。
- `Domain`：不依賴 UI 的型別、草稿與規則。
- `Persistence`：Core Data stack、repository、migration 與 CloudKit。
- `Features`：依群組、帳本、帳號、分類、交易、總覽與設定拆分的 SwiftUI 畫面。

View 不直接包含同步、結算或複雜帳務計算；可測試的領域規則應位於 Domain／service，持久化操作由 repository 負責。

## 資料模型與帳務規則

資料所有權依下列層級管理：

| 擁有者 | 直接擁有的資料 | 說明 |
| --- | --- | --- |
| `LedgerGroup` | `Member`、`LedgerBook`、`LedgerAccount`、`AuditEvent` | 群組負責共享範圍、成員、角色、共用帳號與稽核；成員與帳號不逐帳本重複建立 |
| `LedgerBook` | `LedgerCategory`、`LedgerEntry` | 帳本是分類與交易的隔離邊界；一個群組可有多個帳本 |
| `LedgerCategory` | 子 `LedgerCategory` | 分類以同一帳本內的自我關聯形成分類樹 |
| `LedgerEntry` | `EntrySplit` | 交易代表收入、支出或轉帳；split 記錄群組成員應負擔金額 |

- 每個群組必須至少有一個啟用中的帳本，且啟用中的帳本必須有唯一的預設帳本。
- 建立群組時同步建立名為「主要帳本」的預設帳本。
- 建立帳號的 repository API 以 `LedgerGroup` 為 scope；建立分類與交易則以 `LedgerBook` 為 scope。
- 交易引用的來源與目的帳號必須屬於帳本所屬群組，分類必須屬於交易帳本；分類的 parent 與 child 也必須屬於同一帳本。
- 付款人與 split 成員仍以群組為 scope，但必須與帳本所屬群組一致。
- 帳號餘額由群組內所有帳本引用該帳號的交易共同推導；帳號明細需標示每筆交易所屬帳本。
- 單筆交易只屬於一個帳本；同群組帳號間的轉帳記錄於目前帳本，不建立跨帳本交易關聯。
- `AuditEvent` 保存變更摘要、操作者與時間；交易與設定修改不可靜默覆寫歷史。
- 金額使用 `Decimal`／Core Data Decimal，不使用 `Double` 儲存貨幣。
- 已被交易使用的分類或帳號採封存，不直接刪除。
- CloudKit schema 的 non-optional 欄位必須有合理預設值，relationships 必須符合 CloudKit 模型限制。
- 正式資料模型變更必須建立新 model version、輕量 migration 驗證與舊資料升級測試，不直接破壞既有 schema。

### Model version 與 migration 順序

| Model version | 內容 | Migration 要求 |
| --- | --- | --- |
| V1 | 原始群組直屬帳號、分類與交易模型 | 僅作為既有資料來源，不直接修改 |
| V2 | 新增 `LedgerBook`，讓帳號、分類與交易歸屬帳本，並加入帳號期初餘額與對帳欄位 | 為每個既有群組建立或取得「主要帳本」，再回填所有缺少 `book` 的 V1 物件 |
| V3 | 帳號回歸群組 scope，移除 `LedgerAccount.book`／`LedgerBook.accounts`；分類與交易維持帳本 scope | 使用輕量 migration 移除可選關聯，保留帳號既有 `group`、交易引用、期初餘額與對帳資料；分類與交易缺少 `book` 時仍回填主要帳本 |

V1→V2→V3 採分階段 migration。V2 先建立帳本與可選 `book` 關聯，以程式回填既有分類與交易；V3 再移除帳號與帳本的關聯，帳號既有 `group` 關聯成為唯一 scope。分類與交易暫時保留對 `LedgerGroup` 的直接關聯以相容舊資料與 CloudKit，`LedgerBook` 關聯則是新程式碼的帳本 scope 來源。

回填必須可重複執行且結果一致：App 啟動載入 stores 後執行一次，收到 CloudKit remote change 後也要重新檢查，以涵蓋稍後同步進來的 V1 資料。回填在 background context 進行，只傳遞 object ID；完成後由 persistent history／context merge 更新畫面。

## Core Data 與 Concurrency

- `NSManagedObject` 不是 Sendable，不可跨 actor 或 queue 直接傳遞。
- 不可用 `@unchecked Sendable` 壓掉 `NSManagedObject` 的 concurrency 問題。
- 畫面使用的 view context 資料以 `@MainActor` 管理。
- 背景工作只傳遞 `NSManagedObjectID`，並在目標 context 重新取得物件。
- `NSPersistentHistoryTrackingKey` 與 remote change notifications 必須保持啟用。
- Merge policy、衝突決策與稽核記錄必須一致，不可只依畫面最後顯示結果推測同步成功。

`PersistenceController.prepareShare` 應在 closure 外先讀取分享標題並標記 `@MainActor`，不可在 `@Sendable` closure 捕捉 `LedgerGroup`。

## CloudKit 儲存與分享

持久層包含 private 與 shared stores。使用者建立的群組先進入 private store；接受 CloudKit 分享後的群組進入 shared store。兩者透過同一個 view context 提供畫面查詢。

`LedgerAccount`、`LedgerBook` 及帳本的分類與交易必須與所屬群組位於相同 persistent store。聯絡人挑選只建立 App 內的待邀請成員；真正的 iCloud participant、讀寫權限與分享狀態由 CloudKit Sharing 管理。新增資料時必須依群組或帳本所屬 store 指派正確 persistent store，不可一律寫入 private store。

App 必須呈現未登入 iCloud、暫時不可用、同步中、同步成功、離線及同步失敗等狀態。沒有 iCloud 帳號時仍允許本機記帳，但停用共享邀請並說明原因。

## 聯絡人與隱私

- 只使用系統聯絡人選擇器處理使用者主動選取的聯絡人。
- 不要求讀取或上傳整份通訊錄。
- 裝置專屬 contact identifier 只用於當次表單去重，不持久化或同步。
- App 內待邀請成員與 CloudKit participant 身分必須明確區分。
- 新增第三方分析、crash reporting、廣告、帳號或後端服務前，必須重新稽核資料流、隱私政策與 App Privacy 申報。

## 建置與測試

```bash
open SharedLedger.xcodeproj
```

```bash
xcodebuild build-for-testing \
  -project SharedLedger.xcodeproj \
  -scheme SharedLedger \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

- `⌘B`：Build。
- `⌘R`：執行 App。
- `⌘U`：執行測試。
- `⇧⌘K`：清理 Build Folder 後重建。

所有功能性改動都需通過相關單元／整合測試及 macOS Xcode CI。只有文件變更可省略 App build，但仍需驗證 Markdown 連結與內容責任沒有衝突。

多帳本資料層至少需測試：新群組建立預設帳本、同群組建立多個帳本、封存預設帳本時提升替代帳本、同群組帳號可跨帳本使用且餘額正確、拒絕跨群組帳號與跨帳本分類關聯、V1／V2 舊資料升級，以及重複執行回填的冪等性。

## CloudKit 驗收清單

CloudKit 分享只有在以下項目全部通過後才算完成：

1. App 可在已登入 iCloud 的 Simulator 或實機啟動。
2. Console 不再出現缺少 `remote-notification`。
3. 建立群組後，關閉重開仍保留資料。
4. 邀請者能建立並送出 CloudKit share。
5. 第二個 Apple Account 能接受邀請並看到 shared store 群組。
6. 兩端新增或修改資料後能雙向同步，且資料寫入正確 store。
7. 暫時離線時可編輯，恢復網路後能同步。
8. 衝突、失敗與重試不造成重複資料或無聲遺失。
9. 未登入 iCloud 時顯示友善狀態，而非只在 Console 報錯。
