# Shared Ledger｜App Store 與 TestFlight 上架資訊（繁體中文）

更新日期：2026-07-18  
適用平台：iOS 17 或以上  
Bundle ID：`com.shaunchuang.SharedLedger`

> 本文件依目前產品規格撰寫。正式送審前，必須將文案與「實際上傳的 build」逐項比對；尚未完成或尚未通過實機驗證的功能，不應出現在公開商店文案或截圖中。

## 一、App Store Connect：App 資訊

| 欄位 | 建議內容 | 備註 |
| --- | --- | --- |
| App 名稱 | `Shared Ledger－共享記帳` | 18 個字元；Apple 上限 30 字元 |
| 副標題 | `多人共享、彈性分帳、輕鬆結算` | 14 個字元；Apple 上限 30 字元 |
| 主要語言 | 繁體中文 | 建議先以台灣市場為主 |
| Bundle ID | `com.shaunchuang.SharedLedger` | 必須與 Xcode 專案一致 |
| SKU | `SHAREDLEDGER-IOS-001` | 僅供內部識別，建立後不可更改 |
| 主要類別 | 財經（Finance） | 核心用途為共同收支與分帳 |
| 次要類別 | 生活風格（Lifestyle） | 適用家庭、伴侶、室友與旅行情境 |
| 年齡分級 | 預期為最低分級 | 仍須依 App Store Connect 問卷如實作答，以系統結果為準 |
| Made for Kids | 否 | 本 App 並非兒童導向產品 |
| 價格 | 免費 | 若未來加入付費功能再另行設定 |
| 內容權利 | 不包含第三方內容 | 若未來加入第三方內容須重新確認 |
| 授權協議 | Apple 標準 EULA | MVP 不需自訂 EULA |
| 版本 | `1.0` | 必須與 build 的 marketing version 一致 |
| Copyright | `2026 [你的姓名或公司法定名稱]` | Apple 會自動顯示著作權符號 |

### 必填網址

以下欄位不能填 GitHub repository 首頁代替正式頁面，送審前必須建立可公開瀏覽的網頁：

| 欄位 | 待填內容 |
| --- | --- |
| 隱私權政策 URL | `[https://你的網域/privacy]` |
| 支援 URL | `[https://你的網域/support]` |
| 行銷 URL（選填） | `[https://你的網域/shared-ledger]` |

支援頁面至少應包含聯絡 Email、問題回報方式，以及適用法律要求的聯絡資訊。

## 二、App Store 產品頁文案

### 宣傳文字（Promotional Text）

```text
一起記、一起分、一起結清。Shared Ledger 為家庭、伴侶、室友與旅行團打造，讓共同收支、付款來源與分攤結果清楚透明。
```

### 關鍵字（Keywords）

```text
分帳,共同帳本,家庭記帳,情侶記帳,旅行記帳,費用分攤,收支,結算
```

此字串以 UTF-8 計算為 85 bytes，低於 Apple 的 100 bytes 上限；名稱已包含的 `Shared Ledger` 與「共享記帳」不重複放入關鍵字。

### App 完整描述（Description）

```text
Shared Ledger 是一款為多人共同生活打造的共享記帳 App。無論是家庭日常、伴侶開銷、室友帳務，或旅途中一起分攤費用，都能用同一本帳清楚記錄每筆共同收支。

共同帳務，一眼看懂
把相關成員、帳號與交易整理在同一個群組中，清楚掌握誰付款、費用如何分攤，以及目前的結算狀態。

彈性分帳
依情境使用平均、比例或指定金額分攤，也能只選擇部分成員，處理多人付款與不同分擔方式。

收入、支出與轉帳
記錄群組的收入、支出及帳號之間的轉帳，讓資金流向更清楚。

分類符合你的生活
建立多階層分類，例如「交通－汽車－加油」或「交通－大眾運輸－捷運」，整理帳目不受固定分類限制。

清楚結算
根據群組帳務提供誰應該付給誰的結算建議，減少人工計算與來回確認。

離線也能記帳
暫時沒有網路時仍可記錄；恢復連線後，透過 iCloud 同步群組資料。

重視隱私
Shared Ledger 使用 Apple 提供的系統聯絡人選擇器，只處理你主動選取的聯絡人，不會要求讀取或上傳整份通訊錄。共享與同步由 iCloud 提供。

適合：
・家庭共同開銷
・伴侶生活帳本
・室友房租與日常費用
・朋友聚餐與團體活動
・旅行團共同支出

需要 iOS 17 或以上版本。共享與 iCloud 同步功能需要裝置登入 iCloud；未登入 iCloud 時仍可使用本機記帳功能。
```

### 重要：正式版功能裁切

上方描述是「完整 MVP 版本」文案。若 1.0 build 尚未具備下列任一功能，送審前請刪除對應段落：

- 彈性分帳（平均、比例、指定金額、部分成員、多人付款）。
- 收入、支出與帳號轉帳。
- 多階層分類。
- 結算建議。
- 離線編輯後自動同步。
- CloudKit 群組共享與雙向同步。

### 首版更新說明

首版 App Store Connect 不會顯示「此版本的新功能」欄位。日後更新可使用：

```text
本次更新改善穩定性與使用體驗，並修正已知問題。
```

## 三、App Store 截圖規劃

只使用 build 中確實可操作的畫面；不要用設計稿暗示尚未提供的功能。

| 順序 | 截圖標題 | 建議畫面 |
| --- | --- | --- |
| 1 | `共同帳務，一眼掌握` | 群組總覽與收支摘要 |
| 2 | `每一筆，誰付誰分都清楚` | 交易明細與付款／分攤資訊 |
| 3 | `分帳方式，配合真實生活` | 平均、比例或指定金額分攤 |
| 4 | `帳號與分類，自由整理` | 多帳號與多階層分類 |
| 5 | `誰該付給誰，快速結算` | 結算建議畫面 |
| 6 | `多人共享，資料保持同步` | 群組成員或共享狀態 |

建議至少準備一組目前 App Store Connect 接受的 iPhone 大尺寸截圖；若 build 支援 iPad，也必須準備 iPad 截圖。實際尺寸請以上傳頁當下顯示的規格為準。

## 四、App Review 審查資訊

### 聯絡資訊

| 欄位 | 待填內容 |
| --- | --- |
| 姓名 | `[審查聯絡人姓名]` |
| Email | `[可即時收信的 Email]` |
| 電話 | `[含國碼，例如 +886...]` |
| 登入帳號 | 不適用；App 沒有自建帳號系統 |

### 審查備註（App Review Notes）

```text
Shared Ledger 是一款群組共享記帳 App，沒有自建帳號或密碼系統。

App 可在未登入 iCloud 的狀態下使用本機記帳功能。群組共享功能使用 Apple CloudKit Sharing，因此測試共享時，審查裝置需要登入 iCloud。

建議測試步驟：
1. 啟動 App 並建立一個群組。
2. 新增帳號、分類與交易。
3. 關閉並重新開啟 App，確認本機資料仍存在。
4. 若裝置已登入 iCloud，進入群組共享功能並開啟系統分享介面。

聯絡人功能使用 Apple 系統聯絡人選擇器，只會處理審查者主動選取的聯絡人，不會讀取或上傳整份通訊錄。

若審查期間需要協助，請聯絡：[審查聯絡 Email]
```

若 build 的共享入口、選單名稱或操作路徑不同，請在備註中改成逐步且可重現的實際路徑。

## 五、App Privacy 建議

### 建議判斷

若正式 build 同時符合以下條件，可評估在 App Privacy 選擇「不從此 App 收集資料」：

- 沒有自建後端、第三方分析、廣告、追蹤或外部 crash reporting SDK。
- 帳務資料只儲存在使用者裝置與使用者的 iCloud／CloudKit 範圍，開發者無法存取。
- 聯絡人只透過系統選擇器處理使用者主動選取的項目，且不傳送給開發者或第三方。

這個答案必須先以實際程式碼、SDK 清單與 CloudKit 權限設定做最後確認。只要開發者或第三方能在裝置外存取資料，就必須改選「有收集資料」，並依實際情況申報，例如：

- 使用者內容：群組、交易、備註與分類。
- 財務資訊：使用者輸入的收支與帳務內容。
- 聯絡資訊：若姓名、Email 或電話會傳送給開發者或第三方。
- 識別資訊與診斷資訊：若加入帳號、分析或 crash SDK。

### 隱私權政策至少應說明

- 收集、處理與儲存哪些資料。
- 帳務資料使用 Core Data 與 iCloud／CloudKit 同步。
- 群組共享資料會提供給使用者主動邀請的參與者。
- 聯絡人選擇器的用途，以及不讀取整份通訊錄。
- 資料刪除方式與共享資料的處理方式。
- 第三方服務與 SDK（若有）。
- 聯絡方式與政策更新日期。

## 六、TestFlight：測試資訊

### Beta App Description

```text
Shared Ledger 是一款以群組為中心的共享記帳 App，適合家庭、伴侶、室友與旅行團共同管理收支。

這個 Beta 版本主要驗證群組建立、本機資料保存、聯絡人邀請流程、iCloud／CloudKit 群組共享，以及不同裝置與 Apple Account 之間的同步穩定性。

這是測試版本，功能與資料結構仍可能調整。請勿將它作為唯一且不可替代的正式帳務紀錄。
```

### Feedback Email

```text
[你的 TestFlight 回饋 Email]
```

### What to Test（此版本測試重點）

```text
感謝協助測試 Shared Ledger！請優先測試以下項目：

1. 建立群組，確認名稱與成員資料能正確儲存。
2. 透過系統聯絡人選擇器選擇一位或多位聯絡人，確認不會出現重複或錯誤成員。
3. 新增、修改與瀏覽帳號、分類及交易；關閉 App 後重新開啟，確認資料仍存在。
4. 在已登入 iCloud 的裝置建立共享邀請，確認系統分享介面能正常開啟。
5. 使用另一個 Apple Account 接受邀請，確認能看到共享群組。
6. 在邀請者與受邀者兩端新增或修改資料，確認能雙向同步且不會產生重複資料。
7. 暫時離線時新增或修改資料，恢復網路後確認同步完成。
8. 在未登入 iCloud 的情況下，確認仍可本機記帳，且共享功能會停用並顯示清楚說明。
9. 測試淺色／深色模式、較大文字、VoiceOver，以及不同 iPhone／iPad 方向與尺寸。

回報問題時，請盡量附上：操作步驟、預期結果、實際結果、裝置型號、iOS 版本，以及 TestFlight 截圖或錄影。請勿在回報中包含真實電話、Email 或敏感帳務資料。
```

### TestFlight Beta App Review 備註

```text
The app does not require a proprietary account or password. Local bookkeeping works without iCloud. Cloud sharing is available only when the device is signed in to iCloud and uses Apple's CloudKit Sharing system UI.

To test:
1. Launch the app and create a group.
2. Add an account, category, and entry.
3. Relaunch the app to verify local persistence.
4. On a device signed in to iCloud, open the group sharing action to present the system sharing interface.

The contact flow uses Apple's system contact picker and processes only contacts explicitly selected by the tester.

Contact: [review contact email]
```

英文審查備註可降低審查溝通成本；測試者看到的 Beta 說明與 What to Test 則維持繁體中文即可。

### Beta 測試群組建議

| 群組 | 對象 | 測試重點 |
| --- | --- | --- |
| `Internal QA` | App Store Connect 內部成員 | 每個 build 的冒煙測試與回歸測試 |
| `CloudKit E2E` | 至少兩個不同 Apple Account | 邀請、接受、雙向同步、離線恢復 |
| `External Beta zh-TW` | 外部繁中測試者 | 真實使用情境、易用性、崩潰與版面問題 |

每個 TestFlight build 最多可測試 90 天。第一次提供外部測試的 build 需要通過 TestFlight App Review。

## 七、加密與出口合規

若 App 只使用 iOS／CloudKit／HTTPS 提供的系統加密，沒有自行實作加密演算法、VPN、端對端加密通訊或第三方密碼學函式庫，通常可在專案中設定：

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

並在 App Store Connect 依實際情況回答未使用非豁免加密。送出前仍需檢查所有相依套件與實際功能；不要只依本文件作法律判斷。

## 八、送出前待補資料

- [ ] 確認 App Store 顯示名稱是否已被其他 App 使用。
- [ ] 填入法定姓名／公司名稱與 Copyright。
- [ ] 建立可公開瀏覽的隱私權政策頁面。
- [ ] 建立含有效聯絡資訊的支援頁面。
- [ ] 填入 App Review 聯絡姓名、Email 與電話。
- [ ] 填入 TestFlight Feedback Email。
- [ ] 逐項比對公開描述與實際 build，移除尚未完成的功能。
- [ ] 完成 App Privacy 程式碼與第三方 SDK 稽核。
- [ ] 確認聯絡人用途說明與實際權限行為一致。
- [ ] 確認所有 iPhone／iPad 介面方向與全螢幕設定符合目前 target 設定。
- [ ] 使用已登入 iCloud 的實機或 Simulator 驗證 private/shared stores。
- [ ] 使用兩個不同 Apple Account 完成 CloudKit 分享、接受與雙向同步。
- [ ] 測試未登入 iCloud、離線、恢復連線與資料衝突情境。
- [ ] 準備與實際功能一致的 App Store 截圖。
- [ ] 完成 Export Compliance 問卷與加密設定確認。
- [ ] 填寫年齡分級問卷並確認系統產生的分級。
- [ ] 選擇手動發佈，避免審查通過後在未確認狀態下自動上架。

## 九、Apple 官方欄位限制與參考

- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)：App 名稱最長 30 字元、副標題最長 30 字元；iOS App 必須提供隱私權政策 URL。
- [Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)：宣傳文字最長 170 字元、描述最長 4,000 字元、關鍵字最長 100 bytes，並說明支援 URL 與 App Review 欄位。
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)：TestFlight build 可測試 90 天，並需提供 Beta 說明、測試重點與回饋管道。
- [Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)：Beta App Description 與 Feedback Email 為必要測試資訊。
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)：說明隱私權政策與資料處理申報流程。
