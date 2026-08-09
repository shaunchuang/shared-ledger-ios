# iCloud 分享與權限驗收矩陣

本文件是 Shared Ledger 的 CloudKit Sharing 端到端驗收清單。執行正式版 schema 部署或 App Store 發布前，至少使用兩個不同 Apple Account 完成一次完整驗收。

## 測試前置條件

- 裝置 A：Apple Account A，作為群組 owner。
- 裝置 B：Apple Account B，作為受邀 participant。
- 兩台裝置均已為 Shared Ledger 開啟 iCloud。
- 使用相同 App build 與相同 CloudKit environment。
- V8 schema 已先在 Development 初始化；Production 驗收前已部署相同 schema。
- 測試群組至少包含兩個帳本、一個帳戶、一個分類與一筆可辨識交易。

## A. 建立與接受分享

1. A 建立群組並開啟「邀請／管理 iCloud 共享」。
2. 確認 CKShare owner 已對應到 App owner 的 `Member.cloudParticipantID`。
3. A 邀請 B，權限選擇「可編輯」。
4. B 從系統分享連結接受邀請。
5. B 完成 App 成員身分確認。
6. 驗證 B 的 private `LocalMemberIdentity` 只存在 B 的 private store；共享 `Member.cloudParticipantID` 與目前 CKShare participant ID 一致。
7. B 能看到群組、所有使用中帳本、群組帳戶、分類與既有交易。

預期：App Member 與 CKShare participant 為一對一；同一 participant 不得認領第二個 Member。

執行第 3 步時順便記下：系統分享表單實際列出哪些管道（有沒有 LINE 這類第三方 App、有沒有
「拷貝連結」）。這決定「複製邀請連結」還有多少價值，也是 [邀請投遞設計](INVITE_DELIVERY.md)
下一步的判斷依據。

## A2. 複製邀請連結

1. A 在群組詳情按「複製邀請連結」，確認出現「已複製邀請連結」。
2. 把連結貼到任一通訊軟體傳給 B（走系統分享表單以外的管道）。
3. B 點該連結，能完成與 A 段第 4～7 步相同的加入流程。
4. A 在「從未建立過共享」的新群組上按「複製邀請連結」：應建立 share 並複製到可用連結，
   而不是複製到空值或報錯。
5. 重複按「複製邀請連結」與「邀請／管理 iCloud 共享」數次，確認 CloudKit Dashboard 上
   該群組只有一份 share。
6. 未登入 iCloud 時按下：應顯示可讀的錯誤，而不是靜默失敗。
7. 把連結轉傳給**未受邀**的第三個 Apple Account，確認對方無法加入。

預期：連結可用、同一群組只有一份 share、`publicPermission` 維持 `.none`。

## B. 可編輯 participant

1. B 新增一筆交易。
2. A 等待同步後看到同一筆交易。
3. B 編輯交易；A 能看到修改與稽核紀錄。
4. A 新增另一筆交易；B 能看到更新。
5. 離線 B 後新增一筆交易，再恢復網路。

預期：read/write participant 的本機儲存與 CloudKit export 成功；重新連線後資料最終一致且不產生重複交易。

## C. 唯讀 participant

1. A 在系統共享 UI 將測試 participant 設為 read-only，或以 read-only 邀請新的測試 participant。
2. participant 可以瀏覽群組、帳本、帳戶、分類、交易與報表。
3. participant 不得成功新增、編輯、作廢交易，也不得變更帳本、帳戶、分類、成員或結算資料。
4. App 若仍顯示可寫入入口，任何 repository 寫入仍必須在本機被有效權限檢查拒絕，而不是等 CloudKit export 失敗。

預期：CloudKit `readOnly` 與 App viewer 行為一致；沒有「UI 看似成功、稍後同步失敗」的狀況。

## D. 成員移除與重新邀請

1. A 在 App 將 B 移出群組。
2. 驗證 B 的歷史付款、分攤、交易與稽核關聯仍存在。
3. A 同時在系統共享 UI 移除 B 的 iCloud 存取權。
4. B 不再能讀取更新後的 shared store。
5. 未重新邀請前，B 不得用「建立新成員」方式繞過已移除身分。
6. A 重新啟用原 Member 並重新邀請 B。
7. B 接受後應重新使用原 Member，而不是建立第二份歷史身分。

預期：移除不破壞歷史；重新加入延續同一 App Member，新的 CKShare participant ID 只能綁定該 Member。

## E. participant 自行退出

1. B 從系統共享 UI 停止參與。
2. 驗證 B 的 shared object graph 由 Core Data / CloudKit 分享同步流程移除。
3. A 的 private store 群組與歷史資料保持完整。
4. A 仍能看到 B 過去的付款與分攤歷史。

預期：participant 退出不會刪除 owner 的群組資料。

## F. owner 停止整個共享

1. A 從系統共享 UI 選擇停止共享。
2. App 不得呼叫 `purgeObjectsAndRecordsInZone` 刪除 A 的群組 object graph。
3. A 的群組、帳本、帳戶、分類與交易必須仍在本機 private store。
4. 舊的 `Member.cloudParticipantID` 全部清除，因為 participant ID 只對原 CKShare 有效。
5. B 失去 shared store 存取權。
6. A 再次分享同一群組時，可以建立新的 participant mapping，不被舊 ID 阻擋。

預期：停止協作 ≠ 刪除帳本資料。

## G. 權限與角色矩陣

| App 角色 | 預期 CloudKit 權限 | 交易 | 帳本／帳戶／分類設定 | 成員管理 | iCloud 分享管理 |
| --- | --- | --- | --- | --- | --- |
| owner | owner / read-write | 可 | 可 | 可 | 可 |
| administrator | read-write | 可 | 可 | 可 | 依系統 CKShare role 能力；不可假設等同 owner |
| member | read-write | 可 | 否 | 否 | 否 |
| viewer | read-only | 唯讀 | 唯讀 | 唯讀 | 唯讀 |

App 權限只能比 CloudKit 權限更嚴格，不能讓 CloudKit read-only participant 在 App 中取得實際寫入能力。

## H. 錯誤與恢復

逐項驗證：

- 未登入 iCloud 時建立分享會得到可理解錯誤。
- iCloud 暫時不可用時不破壞本機群組。
- 接受邀請期間離線後可重新嘗試。
- CloudKit import/export 失敗後本機仍可開啟 App，且不會把失敗資料假裝成已同步。
- participant mapping 缺失、重複或不一致時拒絕敏感操作並提供可理解錯誤。
- App 升級 V7 → V8 後既有 Member、交易與 share 資料仍可讀取。

## 發布門檻

只有在以下條件全部成立後，才將「iCloud 分享／權限」標示為完成：

- 自動 CI build-for-testing 與 unsigned archive 通過。
- V7 → V8 migration 測試通過。
- owner + read/write participant + read-only participant 的實機流程通過。
- 複製邀請連結送出的邀請能被接受，且同一群組仍只有一份 share。
- owner 停止共享不刪除本機資料。
- participant 退出只移除自己的 shared graph。
- App role 與 CloudKit effective permission 的所有寫入入口都有一致的本機拒絕規則。
- Development schema 驗證後已部署到 Production。
