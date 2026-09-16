import CoreData
import SwiftUI

/// Resolve the exact book again in the app. Cached widget data is never authority
/// to write, and a stale link must never fall back to another book.
struct WidgetQuickEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var books: FetchedResults<LedgerBook>
    @State private var access = PermissionAccess.unresolved
    @State private var needsIdentity = false
    let kind: EntryKind

    init(bookID: UUID, kind: EntryKind) {
        self.kind = kind
        _books = FetchRequest(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@ AND archivedAt == nil", bookID as CVarArg)
        )
    }

    var body: some View {
        Group {
            if let book = books.first, book.group != nil {
                if needsIdentity, let group = book.group {
                    MemberIdentitySelectionView(group: group, onResolved: reloadAccess)
                        .interactiveDismissDisabled()
                } else if access.isAllowed {
                    NewTransactionView(book: book, initialKind: kind, focusesAmount: true) {
                        dismiss()
                    }
                } else if let message = access.noticeMessage {
                    unavailable(message: message)
                } else {
                    ProgressView()
                }
            } else {
                unavailable(message: LedgerStringKey.widgetBookUnavailable.string())
            }
        }
        .onAppear(perform: reloadAccess)
        .onChange(of: books.first?.objectID) { _, _ in reloadAccess() }
        .onReceive(NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange, object: context
        )) { notification in
            if ContextChangeObserver.touches(notification, .groupPermissions) { reloadAccess() }
        }
    }

    private func reloadAccess() {
        guard let group = books.first?.group else { return }
        needsIdentity = CurrentMemberIdentityRepository().needsResolution(for: group)
        access = PermissionAccess(
            restriction: EffectivePermissionRepository().transactionWriteRestriction(in: group)
        )
    }

    private func unavailable(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .multilineTextAlignment(.center)
            NavigationLink {
                WidgetSettingsView()
            } label: {
                Text(.widgetChooseBook)
            }
            Button { dismiss() } label: { Text(.commonActionDone) }
        }
        .padding()
        .navigationTitle(Text(.widgetQuickEntry))
    }
}
