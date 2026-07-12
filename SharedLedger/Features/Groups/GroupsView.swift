import CoreData
import SwiftUI

struct GroupsView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \LedgerGroup.updatedAt, ascending: false)],
        animation: .default
    ) private var groups: FetchedResults<LedgerGroup>

    @State private var isCreatingGroup = false
    @State private var sharePayload: CloudSharePayload?
    @State private var sharingError: String?

    var body: some View {
        Group {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("建立第一個群組", systemImage: "person.3")
                } description: {
                    Text("邀請家人、朋友或旅伴一起記帳。")
                } actions: {
                    Button("建立群組", systemImage: "plus") {
                        isCreatingGroup = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(groups, id: \.objectID) { group in
                    NavigationLink {
                        GroupDetailView(group: group, onInvite: prepareShare)
                    } label: {
                        Label(group.name ?? "未命名群組", systemImage: "person.3")
                    }
                }
            }
        }
        .navigationTitle("群組")
        .toolbar {
            Button("建立群組", systemImage: "plus") {
                isCreatingGroup = true
            }
        }
        .sheet(isPresented: $isCreatingGroup) {
            NavigationStack {
                CreateGroupView { group in
                    prepareShare(group)
                }
            }
        }
        .sheet(item: $sharePayload) { payload in
            CloudSharingView(payload: payload)
        }
        .alert("無法建立邀請", isPresented: sharingErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(sharingError ?? "請確認 iCloud 狀態後再試。")
        }
    }

    private var sharingErrorBinding: Binding<Bool> {
        Binding(
            get: { sharingError != nil },
            set: { if !$0 { sharingError = nil } }
        )
    }

    private func prepareShare(_ group: LedgerGroup) {
        Task {
            do {
                let (share, container) = try await PersistenceController.shared.prepareShare(for: group)
                sharePayload = CloudSharePayload(
                    share: share,
                    container: container,
                    title: group.name ?? "Shared Ledger 群組"
                )
            } catch {
                sharingError = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack { GroupsView() }
        .environment(
            \.managedObjectContext,
            PersistenceController(inMemory: true).container.viewContext
        )
}
