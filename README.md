# Shared Ledger for iOS

Shared Ledger 是一款以群組為中心的 iOS 共享記帳 App，讓家庭、伴侶、室友與旅行團共同記錄收支、分攤費用並完成結算。

## 文件導覽

每項資訊只由一份文件負責；其他文件應以連結引用，不重複維護同一份規格。

| 文件 | 唯一責任 |
| --- | --- |
| [MVP 產品規格](Docs/MVP.md) | 產品目標、功能範圍、完成度、驗收條件與 P0／P1／P2 路線圖 |
| [架構說明](Docs/ARCHITECTURE.md) | 技術基線、專案設定、資料模型、CloudKit、Concurrency、隱私與建置驗證 |
| [App Store 與 TestFlight](Docs/AppStore_TestFlight_zh-TW.md) | 商店文案、審查資料、TestFlight 測試資訊與送審清單 |
| [ChatGPT 專案指令](Docs/SharedLedger_ChatGPT_Project_Instructions_zh-TW.md) | AI 協作方式、GitHub 工作流程與文件維護規則 |

若文件內容衝突，以表格中負責該領域的文件為準。`README.md` 只作為專案入口，不保存完整產品或架構規格。

## 開始開發

需要 macOS 與可建置 iOS 17 target 的 Xcode。專案直接維護並提交 `SharedLedger.xcodeproj`，不使用 XcodeGen。

```bash
open SharedLedger.xcodeproj
```

第一次在新環境執行時，請在 Xcode 選擇正確的 Apple Developer Team，並確認 Bundle ID、CloudKit container、iCloud、Push Notifications 與 Background Modes 設定符合[架構說明](Docs/ARCHITECTURE.md)。

完整建置、測試與 CloudKit 驗收指令集中在[架構說明](Docs/ARCHITECTURE.md)。

目前產品完成度與下一步以 [MVP 產品規格](Docs/MVP.md)為準；開始工作前仍須重新確認 branch、PR、CI 與近期 commit。
