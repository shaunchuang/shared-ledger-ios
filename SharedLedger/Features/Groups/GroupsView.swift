import SwiftUI

struct GroupsView: View {
    var body: some View {
        ContentUnavailableView(
            "建立第一個群組",
            systemImage: "person.3",
            description: Text("邀請家人、朋友或旅伴一起記帳。"),
            actions: {
                Button("建立群組", systemImage: "plus") {}
                    .buttonStyle(.borderedProminent)
            }
        )
        .navigationTitle("群組")
    }
}

#Preview {
    NavigationStack { GroupsView() }
}

