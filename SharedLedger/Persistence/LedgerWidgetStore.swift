import Foundation

/// The app is the only writer; WidgetKit only reads the atomically replaced file.
/// An unavailable App Group must not silently fall back to an unshared suite.
struct LedgerWidgetStore {
    static let appGroupIdentifier = "group.com.shaunchuang.SharedLedger"
    static let widgetKind = "SharedLedgerSummary"
    static let selectedBookKey = "widget.selectedBookID"
    static var shared: LedgerWidgetStore {
        LedgerWidgetStore(
            directory: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ),
            defaults: UserDefaults(suiteName: appGroupIdentifier)
        )
    }

    let directory: URL?
    let defaults: UserDefaults?
    var isAvailable: Bool { directory != nil && defaults != nil }
    private var snapshotURL: URL? { directory?.appendingPathComponent("widget-summary-v1.json") }

    var selectedBookID: UUID? {
        defaults?.string(forKey: Self.selectedBookKey).flatMap(UUID.init(uuidString:))
    }

    var hasStoredData: Bool {
        selectedBookID != nil || snapshotURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } == true
    }

    func select(bookID: UUID?) {
        if let bookID {
            defaults?.set(bookID.uuidString, forKey: Self.selectedBookKey)
        } else {
            defaults?.removeObject(forKey: Self.selectedBookKey)
        }
    }

    func load() -> LedgerWidgetSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(LedgerWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == LedgerWidgetSnapshot.version,
              snapshot.bookID == selectedBookID else { return nil }
        return snapshot
    }

    func save(_ snapshot: LedgerWidgetSnapshot?) throws {
        guard let snapshotURL else { throw CocoaError(.fileNoSuchFile) }
        if let snapshot {
            try JSONEncoder().encode(snapshot).write(
                to: snapshotURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } else if FileManager.default.fileExists(atPath: snapshotURL.path) {
            try FileManager.default.removeItem(at: snapshotURL)
        }
    }

    func reset() throws {
        select(bookID: nil)
        if isAvailable { try save(nil) }
    }
}
