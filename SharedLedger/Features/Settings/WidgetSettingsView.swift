import CoreData
import SwiftUI

struct WidgetSettingsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.createdAt, ascending: true)]
    ) private var groups: FetchedResults<LedgerGroup>
    @State private var selectedBookID = LedgerWidgetStore.shared.selectedBookID
    private let store = LedgerWidgetStore.shared

    var body: some View {
        Form {
            Section {
                Label(.widgetSettingsIntro, systemImage: "rectangle.on.rectangle")
                Text(.widgetSettingsInstructions)
                    .foregroundStyle(.secondary)
            }
            Section {
                if !store.isAvailable {
                    Text(.widgetSettingsUnavailable)
                } else {
                    Picker(selection: $selectedBookID) {
                        Text(.widgetSettingsSelectBook).tag(UUID?.none)
                        if let selectedBookID, !activeBookIDs.contains(selectedBookID) {
                            Text(.widgetBookUnavailable).tag(Optional(selectedBookID))
                        }
                        ForEach(groups, id: \.objectID) { group in
                            ForEach(BookRepository().books(in: group), id: \.objectID) { book in
                                Text(verbatim: "\(group.name ?? "") · \(book.name ?? "")")
                                    .tag(book.id)
                            }
                        }
                    } label: {
                        Text(.widgetSettingsBook)
                    }
                    if let selectedBookID, !activeBookIDs.contains(selectedBookID) {
                        Text(.widgetBookUnavailable)
                            .foregroundStyle(.secondary)
                    }
                    if groups.isEmpty {
                        NavigationLink {
                            CreateGroupView { _ in }
                        } label: {
                            Label(.widgetCreateGroup, systemImage: "person.3")
                        }
                    }
                }
            } header: {
                Text(.widgetSettingsBook)
            } footer: {
                Text(.widgetSettingsPrivacy)
            }
            Section {
                Text(.widgetSettingsRefresh)
                Text(.widgetSettingsQuickEntry)
            }
        }
        .navigationTitle(Text(.widgetTitle))
        .onChange(of: selectedBookID) { _, id in
            store.select(bookID: id)
            LedgerWidgetCoordinator.shared.refresh()
        }
    }

    private var activeBookIDs: Set<UUID> {
        Set(groups.flatMap { BookRepository().books(in: $0).compactMap(\.id) })
    }
}
