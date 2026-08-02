# 多語系與在地化

> 本文件說明 Shared Ledger 的在地化基礎建設怎麼用。範圍與驗收條件請參考 [MVP 產品規格](MVP.md)的「多語系與在地化」一節。

首波語言是正體中文（`zh-Hant`，開發語言）與英文（`en`）。架構本身不預設只有兩種語言：新增語言只要在 Xcode 加一個 region 並補上 catalog 的翻譯，程式碼不必改。

## 組成

| 元件 | 檔案 | 負責 |
| --- | --- | --- |
| String Catalog | `SharedLedger/Resources/Localizable.xcstrings` | 所有使用者可見文字與複數規則 |
| Info.plist Catalog | `SharedLedger/Resources/InfoPlist.xcstrings` | 系統權限說明這類由 iOS 顯示的文案 |
| 鍵註冊表 | `SharedLedger/Localization/LedgerStringKey.swift` | catalog 的索引，提供編譯期檢查與 `allCases` |
| 查詢層 | `SharedLedger/Localization/LedgerLocalization.swift` | 依 locale 查表、代換參數 |
| SwiftUI 入口 | `SharedLedger/Localization/LedgerStringKey+SwiftUI.swift` | `Text(.key)`、`Label(.key, systemImage:)` |
| 格式化 | `SharedLedger/Localization/LedgerFormatters.swift` | 日期、時間與百分比 |
| 金額 | `SharedLedger/Domain/LedgerCurrency.swift` | 金額格式與精度，**由帳本的幣別決定，不是裝置地區** |

## 新增一段文案

1. 在 `Localizable.xcstrings` 加一筆，同時填正體中文與英文。
2. 在 `LedgerStringKey` 加一個對應的 case，鍵名用 `<區域>.<畫面>.<元素>`。
3. 畫面上用 `Text(.settingsTitle)`；非 UI 情境（通知內容、匯出欄位、錯誤訊息）用
   `LedgerStringKey.settingsTitle.string()`。

兩邊只加一邊的話，`LocalizationTests` 會直接失敗並指出漏掉的鍵，不會等到執行時才變成畫面上的鍵名。

## 規則

- **不在程式碼裡串句子。** 語序與單複數在不同語言會整句改寫，`"你在" + scope + "還有..."` 沒有兩種語言都對的寫法。整句話交給 catalog，參數用 `%1$@`、`%2$@` 讓譯者調換位置。
- **複數交給 catalog 的 plural variation。** 中文沒有單複數變化，所以複數規則有沒有真的生效，只有英文驗得出來；`LocalizationTests.testPluralRulesApplyInEnglish` 就是在守這件事。
- **列舉的顯示名稱走 `displayNameKey` / `titleKey`。** 保留 `displayName` 這類 `String` 屬性給呼叫端，但真正的來源是鍵，測試才能指定語言重跑一次。
- **可以被測試指定語言。** 對外的文案 API 都接受 `locale: Locale? = nil`；傳 `nil` 就是跟著系統語言。任何斷言文案內容的測試都必須指定語言，否則會在英文介面的模擬器上失敗。
- **產品名稱與格式縮寫用 `Text(verbatim:)`。** 明講「這裡不翻譯」，才不會被誤認成漏掉的鍵。
- **金額不進這一套。** 金額的精度與符號由帳本保存的幣別決定，走 `LedgerCurrency`；跟著裝置地區跑會讓同一筆帳在兩台裝置上長得不一樣。
- **日期、時間與百分比走 `LedgerFormatters`。** 需要新的樣式就往那裡加，不要在畫面裡各自組 `DateFormatter`。

## 測試守住什麼

`SharedLedgerTests/LocalizationTests.swift`：

- 兩種語言都真的被編進 App bundle（catalog 沒加進 target 時會直接失敗）。
- 每個鍵在每種語言都有翻譯，而且不會掉回鍵名。
- catalog 與 `LedgerStringKey` 的鍵集合完全一致，兩邊都不能有多的或少的。
- 兩種語言的格式參數位置與型別一致——這是在地化最容易造成 crash 的一種錯，而且只在切到該語言時才會發生。
- 翻譯不是把原文複製過去（例外只有 `CSV` 這種格式縮寫）。
- 複數規則、參數代換、貨幣名稱的括號樣式與百分比的小數點符號。

新增功能時，同一個 PR 就要補齊兩種語言的文案，並檢查長字串在 Dynamic Type 與不同螢幕尺寸下的版面。

## 遷移進度

基礎建設與下列範圍已完成：分頁、設定頁、iCloud 同步、通知（含系統通知內容）、交易（列表、詳情、新增與編輯、篩選面板）、群組與帳本（群組列表與詳情、建立群組、身分確認、成員管理、帳本管理與封存歷史、iCloud 共享錯誤）、帳戶（列表、明細、餘額調整、對帳與新增）、分類（群組分類管理、帳本可用分類、新增、重新命名、合併與內建分類名稱）、設定裡的匯出資料與刪除資料，以及 `EntryKind`、`AccountType`、`MemberRole`、`ReportBookScope`、`SplitMode` 這些跨畫面共用的列舉與貨幣顯示名稱。

跨畫面重複出現的文字集中在 `common.*`：取消、儲存、完成、編輯、好、「請稍後再試。」，以及群組／帳本／帳戶／分類／成員的「未命名」佔位字。遷移其他畫面時直接用這些鍵，不要各自再加一份。

尚未進 catalog 的畫面仍保留硬編碼的正體中文字串，依字串數量排序如下（遷移時一併補上該畫面的 VoiceOver 標籤）：

| 範圍 | 主要檔案 |
| --- | --- |
| 總覽與結算 | `DashboardView`、`SettlementView` |
| 資料層錯誤訊息 | `GroupRepository`、`CategoryRepository`、`BookRepository`、`EntryRepository`、`AccountRepository`、`SettlementRepository`、`EffectivePermissionRepository`、`PersistenceController`、`LedgerExportService`、`GroupReportService`、`LedgerNotificationCoordinator`、`AllocationCalculator`、`SettlementCalculator`、`CloudParticipantStatus` |

遷移過程中 `LedgerSectionHeader`、`LedgerEmptyState` 與 `LedgerNavRow` 暫時同時接受 `LedgerStringKey` 與 `String`；全部遷移完成後要移除 `String` 入口，讓「顯示文字」與「先有一個鍵」在型別上再次成為同一件事。

內建分類（`DefaultCategoryCatalog`）的名稱在建立群組時查一次 catalog 後就寫進 Core Data，之後是使用者自己的資料：改名、合併、封存都照常，切換語言不會回頭改寫。MVP 要求的「用穩定識別碼讓名稱跟著語言走」需要在 `LedgerCategory` 加一個識別欄位與一次 migration，仍留在 P1。

`LedgerExportService` 的欄位標題還是硬編碼的正體中文，所以檔案內容固定用 `exportLocale` 查表，不跟著裝置語言跑。任何在畫面與匯出檔都會出現的列舉（`EntryKind`、`AccountType`、`SplitMode`），在匯出這一側都要記得傳 `locale:`；忘了傳的那一欄會在英文裝置上變成中文標題配英文內容。標題進 catalog 的那一次，這些 `locale:` 要一起拿掉。

## VoiceOver

遷移一個畫面時，同一個 PR 補上這個畫面的 VoiceOver 標籤，不另外排一輪：

- **只有圖示的按鈕一定要有 `accessibilityLabel`。** 工具列的加號、篩選、勾選圖示，沒有標籤就只會被唸成「按鈕」。
- **狀態要進標籤或 `accessibilityValue`。** 「篩選交易」與「篩選交易，已套用 3 個條件」是兩件事；群組與帳本選單用 `accessibilityValue` 帶出目前選的是哪一個。
- **一列資料合成一個元素。** 交易列、明細列這種「欄位名稱 + 值」的組合用 `.accessibilityElement(children: .combine)`，否則使用者要滑三次才聽得懂一行。列裡還有按鈕時改用 `.contain`，才不會把按鈕吃掉。
- **裝飾性圖示標 `accessibilityHidden(true)`。** 空狀態的插圖、列尾的 chevron、金額旁的貨幣代碼都屬於這一類。
- **表單裡沒有可見標籤的輸入框要自己補標籤。** 付款金額、分攤比例這種一列多欄的欄位，標籤要帶上是誰的（「小美 的付款金額」），否則聽起來每一格都一樣。
- **切換型的按鈕補 `.isSelected` trait 與 `accessibilityHint`。** 有沒有被選中不能只靠顏色或勾勾。
