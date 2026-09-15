import CoreData
import SwiftUI

struct WatchSettingsView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.createdAt, ascending: true)])
    private var groups: FetchedResults<LedgerGroup>
    @AppStorage(WatchLedgerService.selectionKey) private var selectedBookID = ""

    var body: some View {
        Form {
            Section {
                Text(.watchSettingsIntro)
                Picker(selection: $selectedBookID) {
                    Text(.watchNone).tag("")
                    ForEach(groups, id: \.objectID) { group in
                        ForEach(BookRepository().books(in: group), id: \.objectID) { book in
                            if let id = book.id {
                                Text(verbatim: "\(group.name ?? "") · \(book.name ?? "")").tag(id.uuidString)
                            }
                        }
                    }
                } label: { Text(.watchBook) }
            } footer: { Text(.watchSettingsPrivacy) }
            Section { Text(.watchSettingsInstructions) }
        }
        .navigationTitle(Text(verbatim: "Apple Watch"))
        .onAppear { WatchLedgerBridge.shared.start() }
        .onChange(of: selectedBookID) { _, _ in WatchLedgerBridge.shared.publish() }
    }
}
