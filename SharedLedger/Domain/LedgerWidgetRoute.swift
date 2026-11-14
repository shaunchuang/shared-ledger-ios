import Foundation

enum LedgerWidgetRoute: Equatable, Identifiable {
    case settings
    case newEntry(bookID: UUID, kind: EntryKind)

    var id: String { url.absoluteString }

    var url: URL {
        var components = URLComponents()
        components.scheme = "sharedledger"
        switch self {
        case .settings:
            components.host = "widget-settings"
        case let .newEntry(bookID, kind):
            components.host = "new-entry"
            components.queryItems = [
                URLQueryItem(name: "book", value: bookID.uuidString),
                URLQueryItem(name: "kind", value: kind.rawValue)
            ]
        }
        // All components are fixed literals or a UUID / enum raw value.
        return components.url!
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "sharedledger", components.path.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        switch components.host {
        case "widget-settings" where items.isEmpty:
            self = .settings
        case "new-entry":
            guard items.count == 2,
                  items.filter({ $0.name == "book" }).count == 1,
                  items.filter({ $0.name == "kind" }).count == 1,
                  let book = items.first(where: { $0.name == "book" })?.value,
                  let bookID = UUID(uuidString: book),
                  let rawKind = items.first(where: { $0.name == "kind" })?.value,
                  let kind = EntryKind(rawValue: rawKind),
                  kind == .expense || kind == .income else { return nil }
            self = .newEntry(bookID: bookID, kind: kind)
        default:
            return nil
        }
    }
}
