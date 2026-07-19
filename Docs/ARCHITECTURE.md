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
- `Features`：依群組、帳本、帳戶、分類、交易、總覽與設定拆分的 SwiftUI 畫面。

View 不直接包含同步、結算或複雜帳務計算；可測試的領域規則應位於 Domain／service，持久化操作由 repository 負責。

## 資料模型與帳務規則

資料所有權依下列層級管理：

| 擁有者 | 直接擁有的資料 | 說明 |
| --- | --- | --- |
| `LedgerGroup` | `Member`、`LedgerBook`、`LedgerAccount`、`LedgerCategory`、`AuditEvent` | 群組負責共享範圍、成員、角色、共用帳戶、分類目錄與稽核；成員、帳戶與分類主資料不逐帳本重複建立 |
| `LedgerBook` | `BookCategoryAssignment`、`LedgerEntry` | 帳本是交易的隔離邊界，並以 assignment 決定可用分類；一個群組可有多個帳本 |
| `LedgerAccount` | `AccountAdjustment` | 餘額調整直接屬於帳戶，不是沒有帳本的交易 |
| `LedgerCategory` | 子 `LedgerCategory` | 分類以同一群組內的自我關聯形成共用分類樹 |
| `BookCategoryAssignment` | 無 | 明確連接同群組的帳本與分類，保存帳本內的啟用狀態與顯示順序 |
| `LedgerEntry` | `EntrySplit` | 交易代表收入、支出或轉帳；split 記錄群組成員應負擔金額 |

- 每個群組必須至少有一個啟用中的帳本，且啟用中的帳本必須有唯一的預設帳本。
- 建立群組時同步建立名為「主要帳本」的預設帳本。
- 建立帳戶、分類與餘額調整的 repository API 分別以 `LedgerGroup`／`LedgerGroup`／`LedgerAccount` 為 scope；交易與帳本分類啟用關聯以 `LedgerBook` 為 scope。
- 交易引用的來源與目的帳戶必須屬於帳本所屬群組；分類必須屬於同一群組，且在交易帳本存在有效的 `BookCategoryAssignment`。分類的 parent 與 child 也必須屬於同一群組。
- 付款人與 split 成員仍以群組為 scope，但必須與帳本所屬群組一致。
- 帳戶餘額由期初餘額、群組內所有帳本引用該帳戶的交易，以及帳戶直屬的 `AccountAdjustment` 共同推導；帳戶明細需標示每筆交易所屬帳本。
- 單筆交易只屬於一個帳本且不得以 `book == nil` 儲存；同群組帳戶間的轉帳記錄於目前帳本，不建立跨帳本交易關聯，並排除於收入／支出統計。
- `AuditEvent` 保存變更摘要、操作者與時間；交易與設定修改不可靜默覆寫歷史。
- 金額使用 `Decimal`／Core Data Decimal，不使用 `Double` 儲存貨幣。
- 已被交易使用的分類或帳戶採封存，不直接刪除；移除 `BookCategoryAssignment` 只代表該帳本停用分類，不得清除歷史交易的分類關聯。已封存帳本、帳戶或分類不得接受新的帳務關聯。
- CloudKit schema 的 non-optional 欄位必須有合理預設值，relationships 必須符合 CloudKit 模型限制。
- 正式資料模型變更必須建立新 model version、輕量 migration 驗證與舊資料升級測試，不直接破壞既有 schema。

### 群組分類與帳本啟用模型

- `LedgerCategory.group` 是分類主資料的權威 scope；`parent` 與 `children` 只能連接同群組分類。分類名稱、階層與群組排序由群組共用，修改時必須建立稽核事件。
- 新增顯式 join entity `BookCategoryAssignment`，至少包含穩定 `id`、`createdAt`、`sortOrder`、`isEnabled`，以及必要的 `book`、`category` 關聯。CloudKit 不依賴 Core Data unique constraint；repository 必須以「同一 book/category 最多一筆有效 assignment」做冪等驗證與修復。
- assignment 的 book、category 與 group root 必須位於相同 persistent store，且 book.group 必須等於 category.group；任何跨群組或跨 store 關聯都由 repository 拒絕。
- 新增或修改交易時，category 除了未封存外，還必須有目前帳本的有效 assignment。讀取歷史交易時不套用此限制，以確保停用或封存後仍能顯示原分類。
- 帳本停用分類時保留 assignment 歷史或以 `isEnabled = false` 表示，不刪除分類及交易關聯；重新啟用同一分類應更新既有 assignment，不建立重複資料。
- 從群組分類管理新增分類時，repository 為所有啟用帳本建立 assignment；從帳本情境新增時只建立目前帳本 assignment，除非使用者明確選擇其他帳本。
- 建立帳本時，由同一套 service 依使用者選擇建立 assignments：群組預設、複製來源帳本或空白。複製的是 assignment 設定，不複製 `LedgerCategory`。
- 群組封存分類前需檢查子分類與歷史引用；父分類仍有啟用子分類時不得留下無法管理的孤兒節點。合併分類必須另行保存舊分類到目標分類的稽核資訊。
- UI 分工固定為「群組設定 → 分類管理」維護分類主資料，「帳本設定 → 使用的分類」維護 assignment；全域 App 設定不直接承載任何群組的即時分類資料。

### 分攤與付款模型方向

- `EntrySplit.amount` 是每位成員最後實際負擔金額，也是淨額與結算引擎的計算來源；比例與指定金額的原始輸入需另行保存，不能只靠最後金額反推。
- 後續 model version 應在 `LedgerEntry` 保存穩定的分攤模式 `equal`／`percentage`／`fixedAmount`，並為 split 保存對應的比例或輸入金額快照。
- 多人付款不可繼續擴充單一 `LedgerEntry.payer`；應新增交易直屬的付款明細 entity，每筆包含付款成員與付款金額，並以 migration 將既有 `payer` 轉為一筆全額付款。
- 分攤與付款驗證集中在 Domain service，由新增、編輯、匯入與同步修復共用；View 不自行決定尾差或合法性。
- 尾差使用交易貨幣的 fraction digits 與穩定排序分配，確保相同輸入在不同裝置產生完全一致的 split，避免 CloudKit 同步衝突。

### Model version 與 migration 順序

| Model version | 內容 | Migration 要求 |
| --- | --- | --- |
| V1 | 原始群組直屬帳戶、分類與交易模型 | 僅作為既有資料來源，不直接修改 |
| V2 | 新增 `LedgerBook`，讓帳戶、分類與交易歸屬帳本，並加入帳戶期初餘額與對帳欄位 | 為每個既有群組建立或取得「主要帳本」，再回填所有缺少 `book` 的 V1 物件 |
| V3 | 帳戶回歸群組 scope，新增帳戶直屬 `AccountAdjustment`，移除 `LedgerAccount.book`／`LedgerBook.accounts`；分類與交易維持帳本 scope | 輕量 migration 保留帳戶既有 `group`、交易、期初餘額與對帳資料；啟動後將舊版無帳本的 `balanceAdjustment` entry 冪等轉為 `AccountAdjustment`，分類與交易缺少 `book` 時回填主要帳本 |
| V4 | 分類提升為群組 scope，新增 `BookCategoryAssignment`；交易維持帳本 scope | 先保留 optional legacy `LedgerCategory.book` 供過渡修復；每個既有分類建立對原帳本的 assignment，不依名稱自動合併。完成 private/shared stores 與混合版本同步驗證後，後續 model version 才移除 legacy 關聯 |

V1→V2→V3→V4 採分階段 migration。V2 先建立帳本與可選 `book` 關聯，以程式回填既有分類與交易；V3 再移除帳戶與帳本的關聯，帳戶既有 `group` 關聯成為唯一 scope。V4 將分類的 `group` 關聯提升為權威 scope，加入 assignment 但暫時保留 legacy `category.book`，避免在 automatic lightweight migration 後失去原帳本資訊。

V4 資料修復對每個既有分類採以下規則：

1. 由既有 `category.group` 或 legacy `category.book.group` 取得群組；兩者衝突時停止自動修復並記錄可診斷錯誤，不猜測資料所有權。
2. 若 legacy book 存在，建立或重用該 book/category 的 assignment；若不存在，為群組的預設帳本建立 assignment。
3. 不以名稱或階層文字自動合併不同分類；即使多本帳本都有「餐飲」，也先保留不同 ID，待使用者透過正式合併流程處理。
4. 新程式碼完成修復後不再寫入 legacy `category.book`；舊版裝置或延遲 CloudKit 記錄仍可能帶入此欄位，因此每次 remote change 後需再次冪等修復。
5. 所有新建 category、assignment、book 與 group 必須位於相同 store；private 與 shared stores 分別驗證，不跨 store 搬移 object。

帳本回填、舊版餘額調整轉換與分類 assignment 修復都必須可重複執行且結果一致：App 啟動載入 stores 後執行一次，收到 CloudKit remote change 後也要重新檢查，以涵蓋稍後同步進來的舊資料。修復在 background context 進行，只傳遞 object ID；完成後由 persistent history／context merge 更新畫面。

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

`LedgerAccount`、`LedgerBook`、群組分類、`BookCategoryAssignment` 及帳本交易必須與所屬群組位於相同 persistent store。聯絡人挑選只建立 App 內的待邀請成員；真正的 iCloud participant、讀寫權限與分享狀態由 CloudKit Sharing 管理。新增資料時必須依群組或帳本所屬 store 指派正確 persistent store，不可一律寫入 private store。

MVP 的 CloudKit share 邊界是整個 `LedgerGroup`：加入群組即能同步該群組的全部帳戶與帳本，暫不提供逐帳本成員名單或只分享單一帳本。畫面隱藏不構成資料權限；若未來需要帳本級隱私，必須另行設計 share 邊界與資料搬移流程。

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

多帳本資料層至少需測試：新群組建立預設帳本、同群組建立多個帳本、封存預設帳本時提升替代帳本、同群組帳戶可跨帳本使用且餘額正確、群組分類可供多本帳本啟用、拒絕跨群組分類與未啟用分類、停用後保留歷史交易、建立帳本時套用／複製 assignment、拒絕寫入已封存 scope、V1／V2／V3 舊資料升級、舊版餘額調整與分類 assignment 轉換、private/shared store 一致性，以及重複執行修復的冪等性。

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
