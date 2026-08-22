import CoreData
import SwiftUI

private struct MemberIdentityRequest: Identifiable {
    let id: NSManagedObjectID
    let group: LedgerGroup
}

struct RootTabView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var identityRequest: MemberIdentityRequest?

    private var identitySignature: String {
        groups.map { group in
            let members = group.members as? Set<Member> ?? []
            let memberState = members
                .map {
                    "\($0.id?.uuidString ?? ""):\($0.invitationStatus ?? ""):\($0.role ?? "")"
                }
                .sorted()
                .joined(separator: ",")
            return "\(group.id?.uuidString ?? ""):\(memberState)"
        }
        .joined(separator: "|")
    }

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label(.tabOverview, systemImage: "chart.pie") }

            NavigationStack {
                TransactionsView()
            }
            .tabItem { Label(.tabTransactions, systemImage: "list.bullet.rectangle") }

            NavigationStack {
                CategoriesRootView()
            }
            .tabItem { Label(.tabCategories, systemImage: "square.grid.2x2") }

            NavigationStack {
                SettlementRootView()
            }
            .tabItem { Label(.tabSettlement, systemImage: "arrow.left.arrow.right.circle") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(.tabSettings, systemImage: "gearshape") }
        }
        .tint(LedgerTheme.primary)
        .toolbarBackground(LedgerTheme.surface.opacity(0.94), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear(perform: presentIdentityResolutionIfNeeded)
        .onChange(of: identitySignature) { _, _ in
            presentIdentityResolutionIfNeeded()
        }
        .sheet(item: $identityRequest) { request in
            NavigationStack {
                MemberIdentitySelectionView(group: request.group) {
                    identityRequest = nil
                }
            }
            .interactiveDismissDisabled()
        }
    }

    private func presentIdentityResolutionIfNeeded() {
        guard identityRequest == nil else { return }
        let repository = CurrentMemberIdentityRepository()
        guard let group = groups.first(where: { repository.needsResolution(for: $0) }) else { return }
        identityRequest = MemberIdentityRequest(id: group.objectID, group: group)
    }
}

#Preview {
    let persistence = PersistenceController(inMemory: true)
    RootTabView()
        .environment(\.managedObjectContext, persistence.container.viewContext)
        .environmentObject(LedgerNotificationCoordinator(persistence: persistence))
}
