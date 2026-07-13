# 架構說明

## 原則

- SwiftUI 採 feature-first 分層。
- Core Data 是裝置上的主要資料來源，CloudKit 負責跨裝置與成員同步。
- View 不直接包含同步或結算邏輯。
- 金額使用 `Decimal`，持久化時使用 Core Data Decimal 屬性。
- 聯絡人只用於使用者主動選擇邀請對象，不上傳整份通訊錄。

## 模組方向

- `App`：生命週期、依賴組裝及根導航。
- `Domain`：不依賴 UI 的型別與規則。
- `Persistence`：Core Data stack、migration 與 CloudKit。
- `Features`：依群組、交易、報表及設定拆分的 SwiftUI 畫面。

## 初始資料關係

- `LedgerGroup` 擁有多個 `Member`、`LedgerAccount`、`LedgerCategory` 與 `LedgerEntry`。
- `LedgerCategory` 以自我關聯形成分類樹。
- `LedgerEntry` 代表收入、支出或轉帳。
- `EntrySplit` 記錄成員應負擔的金額。
- `AuditEvent` 保存變更摘要、操作者與時間。

## CloudKit 注意事項

持久層包含 private 與 shared 兩個 store。使用者建立的群組先進入 private store；接受 CloudKit 分享後的群組則進入 shared store。兩者透過同一個 view context 提供給畫面查詢。

正式啟用共享前，需在 Apple Developer Portal 建立 container、部署 schema，並以至少兩個不同 iCloud 帳號驗證邀請、離線修改、衝突及成員退出流程。聯絡人挑選建立的是 App 內的待邀請成員；真正的 iCloud 參與者與權限由 `UICloudSharingController` 管理。
