import CloudKit
import XCTest
@testable import SharedLedger

final class CloudKitSchemaReadinessTests: XCTestCase {
    func testAvailableAccountIsReadyForSchemaInitialization() {
        XCTAssertEqual(
            PersistenceController.schemaInitializationReadiness(for: .available),
            .ready
        )
    }

    /// 未登入 iCloud 是環境問題，不是程式錯誤：必須擋在
    /// `initializeCloudKitSchema(options:)` 之前，並說明該怎麼登入。
    func testMissingAccountIsBlockedWithSignInInstructions() {
        guard case let .blocked(reason) =
                PersistenceController.schemaInitializationReadiness(for: .noAccount)
        else {
            return XCTFail("未登入 iCloud 時不應視為可以寫入 schema")
        }

        XCTAssertTrue(reason.contains("尚未登入 iCloud"))
        XCTAssertTrue(reason.contains("-initialize-cloudkit-schema"))
    }

    func testRestrictedAccountIsBlocked() {
        guard case .blocked = PersistenceController.schemaInitializationReadiness(for: .restricted)
        else {
            return XCTFail("受限帳號不應視為可以寫入 schema")
        }
    }

    /// 查詢逾時或失敗時只知道「不確定」，此時寧可略過也不要送出注定失敗的請求。
    func testUnknownAccountStatusIsBlocked() {
        for status in [CKAccountStatus.couldNotDetermine, .temporarilyUnavailable] {
            guard case .blocked = PersistenceController.schemaInitializationReadiness(for: status)
            else {
                return XCTFail("帳號狀態 \(status) 不應視為可以寫入 schema")
            }
        }

        guard case .blocked = PersistenceController.schemaInitializationReadiness(for: nil) else {
            return XCTFail("查不到帳號狀態時不應視為可以寫入 schema")
        }
    }
}
