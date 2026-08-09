# 讓受邀者在自己的 App 裡看到邀請

## 問題

目前 Shared Ledger 的邀請流程是標準的 CloudKit Sharing：owner 在 `GroupDetailView`
按「邀請」→ `PersistenceController.prepareShare(for:)` 建立 `CKShare` →
`CloudSharingView`（`UICloudSharingController`）讓 owner 透過訊息／郵件把連結送出去。
受邀者必須**點那條連結**，系統才會啟動 App 並呼叫
`SceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:)`。

如果受邀者已經裝了 App，卻沒收到／沒點那條連結，他在自己的 App 裡看不到任何東西。
本文件回答：能不能讓邀請直接出現在對方 App 裡？

## 結論

**CloudKit 沒有「邀請收件匣」API。** 官方文件裡不存在「列出我被邀請但尚未接受的
share」這種查詢；所有接受路徑（包含 iOS 26 新增的 API）都以 **share URL 為唯一入口**。

因此要讓對方 App 端看得到邀請，只有一條路：**由我們自己把 share URL 送到受邀者的
App**，再由 App 端自行呈現「待接受邀請」清單並完成接受。CloudKit 端的接受動作依然
走官方 API，不需要任何 hack。

## 官方文件依據

| 事實 | 出處 |
| --- | --- |
| `CKShare.url` 是「邀請參與者用的 URL」，**存到伺服器後才有值**，而且「stable and persists across shares and reshares of the same root record」 | [CKShare.url](https://developer.apple.com/documentation/cloudkit/ckshare/1640465-url) |
| 要把 URL 換成 metadata，用 `CKContainer.fetchShareMetadata(with:)` 或 `CKFetchShareMetadataOperation(shareURLs:)`——輸入**只接受 URL**，沒有「列出待接受邀請」的變體 | [CKFetchShareMetadataOperation](https://developer.apple.com/documentation/cloudkit/ckfetchsharemetadataoperation)、[fetchShareMetadata(with:)](https://developer.apple.com/documentation/cloudkit/ckcontainer/fetchsharemetadata(with:completionhandler:)) |
| 拿到 metadata 後以 `CKAcceptSharesOperation` 接受；Core Data 專案則用 `NSPersistentCloudKitContainer.acceptShareInvitations(from:into:)` | [CKAcceptSharesOperation](https://developer.apple.com/documentation/cloudkit/ckacceptsharesoperation)、[acceptShareInvitations(from:into:)](https://developer.apple.com/documentation/CoreData/NSPersistentCloudKitContainer/acceptShareInvitationsFromMetadata:intoPersistentStore:completion:) |
| **尚未接受的 participant 看不到任何共享記錄**；只有 `acceptanceStatus` 變成 `accepted`，CloudKit 才會把記錄放進該使用者的 shared database | [CKShare.ParticipantAcceptanceStatus.pending](https://developer.apple.com/documentation/cloudkit/ckshare/participantacceptancestatus/pending) |
| 這正是「沒有收件匣」的技術原因：shared database 只裝**已接受**的 zone | [CKDatabase.Scope.shared](https://developer.apple.com/documentation/cloudkit/ckdatabase/scope/shared) |
| 官方的邀請投遞方式就是「使用者自己選管道把連結送出去」（Messages / Mail / `ShareLink`），CloudKit 不會自動寄信 | [Sharing CloudKit Data with Other iCloud Users](https://developer.apple.com/documentation/CloudKit/sharing-cloudkit-data-with-other-icloud-users)、[Get the most out of CloudKit Sharing (Tech Talk 10874)](https://developer.apple.com/videos/play/tech-talks/10874/) |
| Core Data 官方範例的做法：`ShareLink` + `CKShareTransferRepresentation` 送出，watchOS 端則自行實作 `userDidAcceptCloudKitShare(with:)` + `acceptShareInvitations` | [Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users) |
| 若受邀者的 Apple Account 尚未跟被邀請的 email／電話對上，`fetchShareMetadata` 會回 `participantMayNeedVerification`，文件明說此時要 `UIApplication.open(shareURL)` 走系統驗證 | [CKFetchShareMetadataOperation](https://developer.apple.com/documentation/cloudkit/ckfetchsharemetadataoperation) |

### iOS 26 的新東西夠不夠用？

- `CKShare.allowsAccessRequests` / `requesters` / `denyRequesters(_:)` / `blockRequesters(_:)`
  與 `CKShareRequestAccessOperation(shareURLs:)`：這是**反向**流程（拿到連結的人回頭
  要求加入），初始化參數一樣是 `shareURLs`，仍然需要先有 URL。而且 iOS 26 beta 的
  release notes 標示 request access API「available in the SDK but currently
  nonfunctional」，不能當成產品方案。
  參考：[CKShare](https://developer.apple.com/documentation/cloudkit/ckshare)
- `CKShare.oneTimeURL(for:)` 與自訂分享 UI 需要
  [`com.apple.developer.icloud-extended-share-access`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-extended-share-access)
  （iOS 26+）。注意該文件的硬性限制：取得的使用者資訊 **「may only use end user
  information transiently to display it to the share participants … may not store
  end user information」**——所以不能把 email／姓名寫進我們自己的資料庫。

結論不變：**URL 一定要靠我們自己送。**

## 現況盤點：App 目前認不出「這是哪個 Apple Account」

這是方案 B 的前置條件，先講清楚。目前程式碼裡**沒有任何 container 層級的使用者識別**，
只有三層各自受限的資訊：

| 層級 | 程式位置 | 知道什麼 | 不知道什麼 |
| --- | --- | --- | --- |
| `CKAccountStatus` | `PersistenceController.swift:172`、`accountStatus(for:)`、`SyncStatusMonitor` | 有沒有登入 iCloud（`.available` / `.noAccount` / `.restricted`） | 是**誰** |
| `share.currentUserParticipant.participantID` → `Member.cloudParticipantID` | `PersistenceController.bindCurrentParticipantIfAvailable`、`GroupRepository.bindCurrentCloudParticipant`、`EffectivePermissionRepository` | 這台裝置在**這個 share 裡**是哪個 participant | 跨 share／跨群組是不是同一人 |
| `LocalMemberIdentity`（private store） | `CurrentMemberIdentityRepository`、`RootTabView.swift:78`、`GroupsView.swift:278` | 使用者**自己選**的群組成員身分 | 這個選擇對不對——App 沒有驗證能力 |

兩個必須記住的限制：

- `CKShare.Participant.ID` 的官方宣告就是 [`typealias ID = String`](https://developer.apple.com/documentation/cloudkit/ckshare/participant/id)，
  文件**沒有任何跨 share 穩定性的保證**。`GroupRepository.swift` 已經註明
  「`cloudParticipantID` is share-local」，這個保守假設要維持，不可以拿它當使用者 ID。
- 受邀者接受 share 後，App 是用 `MemberIdentitySelectionView` **請使用者自己指認**
  「我是哪一位成員」（`claimCurrentMember`）。也就是說目前的身分是「使用者宣告的」，
  不是系統認證的。

未使用的 API 與為什麼不能直接套用在方案 B：

- `CKContainer.userRecordID()`：每個 container、每個 Apple Account 穩定的不透明 ID，
  是最接近「使用者 ID」的東西。但 **owner 在對方接受前拿不到對方的值**——owner 是用
  email／電話邀請的，[`CKFetchShareParticipantsOperation`](https://developer.apple.com/documentation/cloudkit/ckfetchshareparticipantsoperation)
  的文件只保證「participant 會在**接受 share 時**才跟 iCloud 帳號關聯」。收件人 key
  必須在邀請當下就算得出來，所以這條路走不通。
- `CKUserIdentity` 系列（姓名／email）：discoverability 已不可倚賴，而且 iOS 26 的
  [extended share access entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-extended-share-access)
  明文規定這類資訊「may not store」。不能拿來當我們資料庫的 key。

**結論：方案 B 必須自己收識別碼。** 下面「受邀者端流程」第 1 步的「使用者在設定頁登記
email／電話」不是可選項，而是方案 B 的前置工作，目前 App 沒有這個流程。方案 A（邀請碼）
完全不需要身分，這正是它作為備援的價值。

## 三個可行方案

### 方案 A：App 內邀請碼（低成本）

Owner 端產生短碼（例如 6–8 碼），把 `code → shareURL` 寫進 **public database**；
受邀者在 App 裡輸入邀請碼 → 查到 URL → `fetchShareMetadata` → `acceptShareInvitations`。

- 優點：實作最小，不碰使用者身分，沒有隱私爭議。
- 缺點：不是「看得到邀請」，是「輸入邀請碼」；仍需 owner 用別的管道把碼唸給對方。

### 方案 B：public database 邀請信箱（推薦）

Owner 端把邀請寫成 public DB 的一筆 `GroupInvitation`，收件人欄位是**受邀者識別碼的
雜湊**；受邀者的 App 用自己的識別碼算出同一個雜湊去查，查到就在 App 裡顯示「你有一則
待接受的邀請」，按下去直接接受。搭配 `CKQuerySubscription` 還能推播通知。

- 優點：真正做到「對方 App 端看得到邀請」，而且接受動作完全走官方 API。
- 缺點：需要多一個 public DB record type、一套識別碼登記流程與清理機制。

### 方案 C：只優化現況（不改架構）

用 SwiftUI `ShareLink` + `CKShareTransferRepresentation` 取代／並存
`UICloudSharingController`，並在 owner 端補上「複製邀請連結」按鈕，讓 owner 能用任何
管道（LINE、WhatsApp）貼給對方。

- 優點：幾乎沒有風險，一天內可完成。
- 缺點：受邀者 App 端還是空的。

### 建議

**B 為主、A 為備援、C 立即先做。**
C 是現況的明顯缺口（目前沒有「複製連結」，owner 只能用系統分享表單），先補；
B 才是問題的正解；A 用來救「雜湊對不上」的情境（受邀者用的 Apple Account email 跟
owner 輸入的不同）。

## 該不該加登入帳號？——不建議

既然 App 認不出目前的 Apple Account，直覺的下一步是「那就加登入吧」。**不要。**

### 登入解決不了這個問題

Sign in with Apple 給的是一組穩定的 app 內使用者 ID，但 **owner 邀請時手上只有對方的
email／電話**，不是對方的 SIWA ID。更麻煩的是 SIWA 允許使用者隱藏真實信箱，換來一個
`@privaterelay.appleid.com` 位址——owner 永遠不會去輸入那串位址。

所以加了登入，owner 一樣算不出收件人 key，一樣得靠「使用者自行登記聯絡方式」的目錄來
對應。**而那個目錄不需要登入也能做。** 登入沒有帶來任何額外能力。

### 登入會製造一個會分岔的第二身分

資料層是 CloudKit：能不能讀寫某個群組，完全由 Apple Account 對應的 CKShare
participant 決定（`EffectivePermissionRepository` 就是在做這件事）。App 帳號管不到這件事。

加上 app 帳號之後，「使用者用 Apple Account X 接受了 share，卻用 app 帳號 Y 登入」是
完全合法的組合。此時權限還是看 X，Y 只會製造錯誤的期待，以及一整類新的 mismatch。
這個專案已經為了單一身分的錯配寫了 `SharingError.participantIdentityMismatch` 與
`EffectivePermission.participantMismatch` 的防線；再引入第二套身分，等於自願把這個
問題面積放大一倍。

### App Store 審查規則不站在登入這邊

[App Review Guideline 5.1.1(v) Account Sign-In](https://developer.apple.com/app-store/review/guidelines/) 明文：

> If your app doesn't include significant account-based features, let people use it
> without a login. … Apps may not require users to enter personal information to
> function, except when directly relevant to the core functionality of the app or
> required by law. … **inviting friends to use the app are not considered core app
> functionality.**

記帳這件事本身完全不需要帳號，而「邀請朋友」被同一條規則明確排除在核心功能之外。強制
登入有被退件的風險，就算過了也只是白白增加首次啟動的摩擦。同一條還規定：一旦支援建立
帳號，就**必須在 App 內提供刪除帳號**。

### 也牴觸本專案已經寫下的原則

- `ARCHITECTURE.md`：「沒有 iCloud 帳號時仍允許本機記帳」——目前 App 沒有任何硬性
  前置條件就能用，這是刻意的。
- `ARCHITECTURE.md`「聯絡人與隱私」：「新增第三方分析、crash reporting、廣告、**帳號**
  或後端服務前，必須重新稽核資料流、隱私政策與 App Privacy 申報。」

### 什麼情況才該重新考慮

- 要支援 Android／Web（脫離 Apple 生態系）
- 要自建後端取代 CloudKit
- 出現真正跨 Apple Account 的商業需求

這三件事都不在目前路線上。

### 該做的是「聯絡方式登記」，那不是登入

方案 B 需要的東西比登入小得多：一個 **opt-in 的設定項**，使用者輸入 email／電話，App
只把加鹽雜湊寫進 public DB。

- 完全選擇性，不登記也不影響任何既有功能
- 沒有密碼、沒有 session、沒有 token，不構成「帳號」，因此沒有 5.1.1(v) 的刪除帳號義務
  （但仍要提供「取消登記」，並併入現有的「刪除本機個人資料」流程）
- 目的是「讓別人找得到我」的目錄，不是「證明我是誰」的驗證

**要誠實面對的弱點**：這個登記沒有驗證，任何人都可以登記別人的 email，於是收到本來要給
別人的邀請卡片。要不要為此做驗證碼？我的判斷是**不做**：

- 它不會洩漏帳務資料。`publicPermission` 維持 `.none`，冒名者就算拿到 share URL 也
  無法接受——真正的授權關卡是 CKShare 本身，不是這個目錄。
- 它洩漏的是「有人邀請了這個 email」這件事，而 public DB 裡只存雜湊、不存原文，攻擊者
  必須先知道那個 email 才能查。
- 做驗證碼需要能寄信的後端，那才是真的把這個 App 變成有後端的 App——為了一個 CKShare
  已經擋住的風險付這個代價不划算。

代價是真正的收件人可能收不到卡片。緩解方式：保留系統分享連結這條路（方案 C），任何時候
都能繞過目錄直接送 URL。

## 方案 B 的落地設計（對應本專案）

### 資料

Public database 新增 record type `GroupInvitation`：

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `recipientHash` | String（queryable） | `SHA256(normalize(email or phone) + containerSalt)` |
| `shareURL` | String | `CKShare.url.absoluteString` |
| `expiresAt` | Date | 建議 14 天 |

**刻意不存**群組名稱、owner 名稱、email 原文。標題與 owner 資訊由受邀者端在
`fetchShareMetadata` 成功後從 `CKShare.Metadata` 讀，而非放在 public DB 裡——這樣
即使有人猜到雜湊，也只拿到一條對他無效的 URL（見下方「安全性」）。

### Owner 端流程

1. `prepareShare(for:)` 之後、`CloudSharingView` 存檔成功
   （`cloudSharingControllerDidSaveShare`）時，`csc.share?.url` 才會有值。
2. 對 owner 在 `ContactPicker` 選到的每個 email／電話，算 `recipientHash`，寫入
   `GroupInvitation`（recordName 用 `hash + "-" + shareRecordName`，避免同一人被兩個
   群組邀請時互相覆蓋）。
3. 當該 participant 的 `acceptanceStatus` 變成 `.accepted`，或超過 `expiresAt`，刪掉
   對應的 `GroupInvitation`。

### 受邀者端流程

1. 使用者在設定頁登記自己的 email／電話（我們自己收，不是讀 Apple Account——
   CloudKit 的 user discoverability 已不可靠，且 iOS 26 entitlement 明文禁止儲存）。
2. App 啟動、進前景，以及收到 `CKQuerySubscription` 推播時，查
   `recipientHash == myHash && expiresAt > now`。
3. 有結果就在群組列表頂端顯示「待接受邀請」卡片。
4. 使用者點「加入」→ `CKContainer.fetchShareMetadata(with: url)` →
   `PersistenceController.acceptShare(metadata:)`（已存在，會導進 `sharedStore`）。
5. 錯誤處理：
   - `participantMayNeedVerification` → 依官方文件改走 `UIApplication.open(url)`。
   - `unknownItem` / metadata 抓不到 → 邀請已被撤銷，移除卡片。

### 現有程式的接點

| 位置 | 需要的改動 |
| --- | --- |
| `PersistenceController.acceptShare(metadata:)` | 已可直接重用，不必改 |
| `PersistenceController` | 新增 `fetchShareMetadata(for: URL)` 包裝 |
| `CloudSharingView.Coordinator.cloudSharingControllerDidSaveShare` | 存檔成功後寫出 `GroupInvitation` |
| `Features/Groups/ContactPicker.swift` | 把選到的識別碼傳給邀請寫入流程 |
| `Features/Groups/GroupsView.swift` | 顯示「待接受邀請」區塊 |
| `Persistence/`（新檔） | `InvitationInboxService`：雜湊、寫入、查詢、清理 |
| `Domain/LedgerNotification*` | 新增一種「收到群組邀請」通知 |
| `SharedLedger.entitlements` | 不需要改（同一個 container 的 public DB） |

### 安全性與隱私

- 目前 `CloudSharingView` 的 `availablePermissions` 是
  `[.allowPrivate, .allowReadOnly, .allowReadWrite]`，**沒有 `.allowPublic`**，所以
  `publicPermission` 維持 `.none`：只有被 owner 邀請的 participant 能接受這個 share。
  這是方案 B 的安全前提——share URL 外流不等於資料外流。**不要**為了方便加上
  `.allowPublic`。
- public DB 只放雜湊值，不放 email 原文；雜湊要加 app 專屬 salt，避免彩虹表。
- 不要把 `CKUserIdentity`／owner 姓名寫進任何持久儲存（iOS 26 extended share access
  entitlement 的明文限制）。
- CloudKit Dashboard 上把 `GroupInvitation` 的 security role 收到最小：`_icloud` 可
  Create / Read，`_creator` 可 Write / Delete，不要開 `_world`。

### 驗收（併入 `Docs/ICLOUD_SHARING_VALIDATION.md`）

1. B 已登記 email 且已裝 App：A 邀請後，B **不點任何連結**，開 App 就看得到邀請卡片，
   按下即加入。
2. B 未登記 email：不出現卡片；改用邀請碼（方案 A）可加入。
3. A 撤銷邀請：B 的卡片在下次查詢後消失。
4. 邀請過期：卡片消失，且 record 被清掉。
5. B 的 Apple Account email 與 A 輸入的不同：出現 `participantMayNeedVerification`，
   App 自動改開系統連結，仍能完成加入。
6. 非受邀的第三方即使拿到 share URL 也無法加入（驗證 `publicPermission == .none`）。

## 不建議的做法

- **靠 CloudKit 自己通知受邀者**：CloudKit 不會主動寄信或推播給未接受的 participant。
- **等 `CKShareRequestAccessOperation`**：iOS 26 beta release notes 標示尚未運作，且
  仍需要 URL。
- **把 share URL 放進可被無條件列舉的 public record**：即使 URL 對外人無效，也會洩漏
  「誰邀請了誰」的社交圖。
