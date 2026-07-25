# 結算引擎

本文件記錄 P0 債務與結算功能的第一版實作規則。

## 計算範圍

- 成員淨額與結算以單一 `LedgerBook` 為帳務邊界，不跨帳本直接互抵。
- 支出：實際付款增加成員應收，分攤金額增加成員應付。
- 收入／退款：方向與支出相反，使共享退款可以降低既有債務。
- 轉帳與帳戶餘額調整不列入成員結算。
- 已作廢交易不列入目前淨額，但交易與作廢稽核歷史仍保留。
- 所有計算使用群組 `currencyCode` 的最小貨幣單位，不固定假設兩位小數。

## 建議付款

`SettlementCalculator` 先將每位成員換算為淨額，再在債務人與債權人之間求出可將非零餘額歸零的付款清單。演算法依非零餘額的成員人數分成兩段：

- **10 人以內**：完整搜尋最少付款筆數。搜尋以狀態陣列作為 memo key，筆數相同時依成員索引（已按 UUID 穩定排序）比較，讓結果可重現。
- **超過 10 人**：改用貪婪配對，重複將目前最大債務人與最大債權人相抵。完整搜尋在此規模會呈指數成長並卡住主執行緒；貪婪解保證最多 `n - 1` 筆、複雜度 `O(n log n)`，且同樣把每位成員的餘額歸零，只是不保證筆數最少。

兩條路徑都保證所有建議付款金額為正，且套用後所有成員餘額歸零。

## 資料尚未同步時的行為

共享資料庫會各自同步 `LedgerEntry`、`EntryPayment`、`EntrySplit` 與 `Member`，因此剛匯入的交易可能暫時缺少部分付款／分攤列，或缺少它們指向的 `Member`。

`SettlementRepository.snapshot(in:)` 會**逐筆隔離**這類交易，而不是讓整本帳的結算失敗：無法解讀的交易不列入計算，並透過 `skippedEntryCount` 回報，結算頁再顯示「N 筆交易尚未同步完成」。其餘交易的淨額與建議付款維持可用。

## 結算紀錄

第一版不新增 Core Data model version。結算使用既有不可變 `AuditEvent` 保存：

- `settlement.recorded`：新增全額或部分結算。
- `settlement.reversed`：撤銷既有結算，不刪除原始紀錄。

Audit payload 保存 `settlementID`、`bookID`、付款人、收款人、金額與外部付款備註。計算目前淨額時只套用尚未撤銷的結算紀錄。

## 權限

- owner、administrator、member 可記錄與撤銷結算。
- viewer 或尚未完成目前成員身分確認者只能查看。
- 已封存帳本不能新增結算。

## 驗證

- 純 Domain 結算演算法已以 Swift 編譯 smoke test 驗證支出、收入方向與部分結算。
- `SharedLedgerTests/SettlementCalculatorTests.swift` 已加入 `SharedLedgerTests` Sources build phase，涵蓋 Domain 與 repository 情境。
- 大型群組：24 人平均分攤與 16 人多付款人不平均兩種情境，驗證建議付款筆數不超過 `n - 1`、金額皆為正，且套用後所有餘額歸零。
- 同步中斷：以 split 的 `member` 為 nil 模擬尚未同步的成員，驗證該筆交易被隔離、`skippedEntryCount` 為 1，其餘交易的淨額與建議付款不受影響。

## 尚待端到端驗證

- 兩個 Apple Account 對 shared store 的結算新增、撤銷與同步。
- 離線新增結算後恢復連線的合併行為。
- 實機確認大型群組（>10 人）在結算頁的實際反應時間。
