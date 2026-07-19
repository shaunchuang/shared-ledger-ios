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
- `Features`：依群組、帳號、分類、交易、總覽與設定拆分的 SwiftUI 畫面。

View 不直接包含同步、結算或複雜帳務計算；可測試的領域規則應位於 Domain／service，持久化操作由 repository 負責。

## 資料模型與帳務規則

- `LedgerGroup` 擁有多個 `Member`、`LedgerAccount`、`LedgerCategory`、`LedgerEntry` 與 `AuditEvent`。
- `LedgerCategory` 以自我關聯形成分類樹。
- `LedgerEntry` 代表收入、支出或轉帳；`EntrySplit` 記錄成員應負擔金額。
- `AuditEvent` 保存變更摘要、操作者與時間；交易與設定修改不可靜默覆寫歷史。
- 金額使用 `Decimal`／Core Data Decimal，不使用 `Double` 儲存貨幣。
- 已被交易使用的分類或帳號採封存，不直接刪除。
- CloudKit schema 的 non-optional 欄位必須有合理預設值，relationships 必須符合 CloudKit 模型限制。
- 正式資料模型變更必須建立新 model version、輕量 migration 驗證與舊資料升級測試，不直接破壞既有 schema。

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

聯絡人挑選只建立 App 內的待邀請成員；真正的 iCloud participant、讀寫權限與分享狀態由 CloudKit Sharing 管理。新增資料時必須依群組所屬 store 指派正確 persistent store，不可一律寫入 private store。

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
