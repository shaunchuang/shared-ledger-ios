import CloudKit
import XCTest
@testable import SharedLedger

final class LedgerSyncStatusTests: XCTestCase {
    private static let zhHant = Locale(identifier: "zh-Hant")
    private static let english = Locale(identifier: "en")
    private static let supportedLocales = [zhHant, english]

    func testAvailableAccountWithNothingInFlightIsUpToDate() {
        let state = LedgerSyncStateReducer.state(
            from: LedgerSyncInputs(accountStatus: .available)
        )
        XCTAssertEqual(state, .upToDate)
    }

    func testAccountProblemsOutrankEverythingElse() {
        // 帳號沒解決之前，網路與同步事件都不會改變結果，所以它們不該蓋掉真正的原因。
        let signedOut = LedgerSyncInputs(
            accountStatus: .noAccount,
            isNetworkAvailable: false,
            hasActiveEvent: true,
            lastEventError: "先前的錯誤"
        )
        XCTAssertEqual(LedgerSyncStateReducer.state(from: signedOut), .signedOut)

        let restricted = LedgerSyncInputs(accountStatus: .restricted, hasActiveEvent: true)
        XCTAssertEqual(LedgerSyncStateReducer.state(from: restricted), .restricted)

        for status in [CKAccountStatus.couldNotDetermine, .temporarilyUnavailable] {
            XCTAssertEqual(
                LedgerSyncStateReducer.state(from: LedgerSyncInputs(accountStatus: status)),
                .undetermined
            )
        }
    }

    func testOfflineOutranksAFailedEvent() {
        // 離線本身就解釋了失敗。顯示「同步失敗」會讓人以為資料出了問題，
        // 而實際上只是還沒連上網。
        let inputs = LedgerSyncInputs(
            accountStatus: .available,
            isNetworkAvailable: false,
            lastEventError: "無法連線到 iCloud"
        )
        XCTAssertEqual(LedgerSyncStateReducer.state(from: inputs), .offline)
    }

    func testActiveEventOutranksAPreviousFailure() {
        let inputs = LedgerSyncInputs(
            accountStatus: .available,
            hasActiveEvent: true,
            lastEventError: "先前的錯誤"
        )
        XCTAssertEqual(LedgerSyncStateReducer.state(from: inputs), .syncing)
    }

    func testFailureIsReportedWithItsReason() {
        let inputs = LedgerSyncInputs(
            accountStatus: .available,
            lastEventError: "iCloud 儲存空間不足"
        )
        XCTAssertEqual(
            LedgerSyncStateReducer.state(from: inputs),
            .failed("iCloud 儲存空間不足")
        )
    }

    func testUnknownAccountStatusFallsBackToNetworkState() {
        // 剛啟動還沒問到帳號狀態時，至少要講得出網路的情況。
        XCTAssertEqual(
            LedgerSyncStateReducer.state(from: LedgerSyncInputs(isNetworkAvailable: true)),
            .undetermined
        )
        XCTAssertEqual(
            LedgerSyncStateReducer.state(from: LedgerSyncInputs(isNetworkAvailable: false)),
            .offline
        )
    }

    func testOverlappingEventsStaySyncingUntilTheLastOneFinishes() {
        var tracker = LedgerSyncEventTracker(
            inputs: LedgerSyncInputs(accountStatus: .available)
        )
        let importID = UUID()
        let exportID = UUID()

        tracker.apply(identifier: importID, isFinished: false, succeeded: false, errorMessage: nil, endDate: nil)
        tracker.apply(identifier: exportID, isFinished: false, succeeded: false, errorMessage: nil, endDate: nil)
        XCTAssertEqual(tracker.state, .syncing)

        tracker.apply(identifier: importID, isFinished: true, succeeded: true, errorMessage: nil, endDate: Date())
        // 匯出還沒結束，不能因為匯入先完成就宣告同步結束。
        XCTAssertEqual(tracker.state, .syncing)

        tracker.apply(identifier: exportID, isFinished: true, succeeded: true, errorMessage: nil, endDate: Date())
        XCTAssertEqual(tracker.state, .upToDate)
    }

    func testASuccessfulEventClearsAnEarlierFailure() {
        var tracker = LedgerSyncEventTracker(
            inputs: LedgerSyncInputs(accountStatus: .available)
        )
        let failing = UUID()
        tracker.apply(identifier: failing, isFinished: false, succeeded: false, errorMessage: nil, endDate: nil)
        tracker.apply(
            identifier: failing,
            isFinished: true,
            succeeded: false,
            errorMessage: "iCloud 服務忙碌中",
            endDate: Date()
        )
        XCTAssertEqual(tracker.state, .failed("iCloud 服務忙碌中"))

        let recovering = UUID()
        let finishedAt = Date()
        tracker.apply(identifier: recovering, isFinished: false, succeeded: false, errorMessage: nil, endDate: nil)
        tracker.apply(
            identifier: recovering,
            isFinished: true,
            succeeded: true,
            errorMessage: nil,
            endDate: finishedAt
        )

        // 失敗的原因已經不成立，繼續顯示只會讓使用者以為問題還在。
        XCTAssertEqual(tracker.state, .upToDate)
        XCTAssertEqual(tracker.inputs.lastSuccessfulSync, finishedAt)
        XCTAssertNil(tracker.inputs.lastEventError)
    }

    func testAFailedEventKeepsTheEarlierSuccessTimestamp() {
        var tracker = LedgerSyncEventTracker(
            inputs: LedgerSyncInputs(accountStatus: .available)
        )
        let succeeded = UUID()
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)
        tracker.apply(identifier: succeeded, isFinished: true, succeeded: true, errorMessage: nil, endDate: syncedAt)

        let failed = UUID()
        tracker.apply(
            identifier: failed,
            isFinished: true,
            succeeded: false,
            errorMessage: "無法連線到 iCloud",
            endDate: Date()
        )

        // 上一次成功同步的時間仍然是真的，不能因為之後失敗就抹掉——那是使用者
        // 判斷「有多少資料還沒上去」的唯一依據。
        XCTAssertEqual(tracker.inputs.lastSuccessfulSync, syncedAt)
        XCTAssertEqual(tracker.state, .failed("無法連線到 iCloud"))
    }

    func testEveryStateHasATitleAndAnExplanationInEveryLanguage() {
        for state in Self.allStates {
            for locale in Self.supportedLocales {
                let title = state.titleKey.string(locale: locale)
                let detail = state.detail(lastSuccessfulSync: nil, locale: locale)
                let context = "\(state) / \(locale.identifier)"

                XCTAssertFalse(title.isEmpty, "\(context) 少了標題")
                XCTAssertFalse(detail.isEmpty, "\(context) 少了說明文字")
                // 沒翻到的鍵會原封不動掉出鍵名，看起來也「有文字」。
                XCTAssertNotEqual(title, state.titleKey.rawValue, context)
                XCTAssertFalse(detail.contains("sync.state."), context)
            }
        }
    }

    func testWorryingStatesSayThatLocalDataIsStillThere() {
        // 未登入、離線或同步失敗時，使用者最先擔心的是記到一半的帳有沒有不見。
        // 這些狀態的說明必須自己講清楚，不能預設使用者懂 CloudKit 的離線行為，
        // 而且兩種語言都要講——這句話最容易在翻譯時被省略成單純的錯誤描述。
        let reassurance = [
            Self.zhHant: "本機",
            Self.english: "this device"
        ]
        for state in Self.allStates where state.needsLocalDataReassurance {
            for (locale, token) in reassurance {
                XCTAssertTrue(
                    state.detail(lastSuccessfulSync: nil, locale: locale).contains(token),
                    "\(state) / \(locale.identifier) 沒有說明帳務仍保存在本機"
                )
            }
        }
    }

    private static let allStates: [LedgerSyncState] = [
        .signedOut, .restricted, .undetermined, .offline, .syncing, .upToDate, .failed("原因")
    ]

    func testOnlyRecoverableStatesOfferARecheck() {
        // 未登入與受限要去系統設定處理，同步中與已同步沒有什麼好重試的；
        // 放一顆按鈕只會讓人以為不按就不會好。
        XCTAssertTrue(LedgerSyncState.failed("原因").suggestsRetry)
        XCTAssertTrue(LedgerSyncState.offline.suggestsRetry)
        XCTAssertTrue(LedgerSyncState.undetermined.suggestsRetry)
        XCTAssertFalse(LedgerSyncState.signedOut.suggestsRetry)
        XCTAssertFalse(LedgerSyncState.restricted.suggestsRetry)
        XCTAssertFalse(LedgerSyncState.syncing.suggestsRetry)
        XCTAssertFalse(LedgerSyncState.upToDate.suggestsRetry)
    }

    func testUpToDateDetailNamesTheLastSyncTime() {
        let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let detail = LedgerSyncState.upToDate.detail(
            lastSuccessfulSync: syncedAt,
            locale: Self.zhHant
        )
        XCTAssertTrue(detail.contains("最後同步時間"))

        let withoutTimestamp = LedgerSyncState.upToDate.detail(
            lastSuccessfulSync: nil,
            locale: Self.zhHant
        )
        XCTAssertFalse(withoutTimestamp.contains("最後同步時間"))

        // 時間戳本身也要跟著語言走，不能固定用裝置地區的寫法。
        XCTAssertNotEqual(
            LedgerFormatters.timestamp(syncedAt, locale: Self.zhHant),
            LedgerFormatters.timestamp(syncedAt, locale: Locale(identifier: "en_US"))
        )
    }

    func testCloudKitErrorsAreTranslatedIntoActionableText() {
        let expectations: [CKError.Code: (zh: String, en: String)] = [
            .quotaExceeded: ("儲存空間", "storage"),
            .networkUnavailable: ("網路", "network"),
            .notAuthenticated: ("登入", "signed in")
        ]
        for (code, tokens) in expectations {
            XCTAssertTrue(
                LedgerSyncErrorMessage.text(for: CKError(code), locale: Self.zhHant)
                    .contains(tokens.zh),
                "\(code) zh-Hant"
            )
            XCTAssertTrue(
                LedgerSyncErrorMessage.text(for: CKError(code), locale: Self.english)
                    .contains(tokens.en),
                "\(code) en"
            )
        }

        // 不認得的錯誤仍要有文字，不能讓畫面上出現空白的失敗原因。
        struct OtherError: LocalizedError {
            var errorDescription: String? { "其他錯誤" }
        }
        XCTAssertEqual(LedgerSyncErrorMessage.text(for: OtherError()), "其他錯誤")
    }
}
