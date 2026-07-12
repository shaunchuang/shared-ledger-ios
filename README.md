# Shared Ledger for iOS

Shared Ledger 是一款以群組為中心的共享記帳 App。第一版聚焦於多人共同管理帳號、階層式分類、分帳與結算，並支援離線使用及 iCloud 同步。

## 技術基線

- Swift 5.9+
- SwiftUI
- iOS 17+
- Core Data + CloudKit
- XcodeGen 管理專案設定

## MVP 功能

- 從聯絡人或邀請連結加入群組
- 一個群組可包含多個記帳帳號
- 任意階層的自訂分類
- 收入、支出及帳號轉帳
- 彈性分帳與群組結算
- 擁有者、管理員、成員及唯讀權限
- 修改歷史
- 基本月報表
- 離線記帳及 iCloud 同步

## 開始開發

需要 macOS、Xcode 15.3 以上版本與 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen
xcodegen generate
open SharedLedger.xcodeproj
```

第一次執行前：

1. 在 Apple Developer 帳號建立 CloudKit container。
2. 將 `SharedLedger/SharedLedger.entitlements` 內的 placeholder container identifier 換成實際值。
3. 在 Xcode 選擇開發團隊並確認 Signing & Capabilities。

## 專案狀態

目前是 Sprint 0：專案骨架、導航、Core Data schema 與基礎領域模型。後續工作請參考 [MVP 規格](Docs/MVP.md) 與 [架構說明](Docs/ARCHITECTURE.md)。

