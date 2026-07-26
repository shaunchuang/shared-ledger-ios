import Contacts
import ContactsUI
import SwiftUI

/// CNContactPickerViewController 是跑在 ContactsViewService 的遠端視圖，
/// 使用者確認或取消後會自行 dismiss；若直接作為 SwiftUI sheet 的內容，
/// 它的自我 dismiss 會與 SwiftUI 的 presentation 狀態互相衝突，
/// 連帶把外層的 sheet（建立群組表單）一起關閉。
/// 因此改由一個中介 UIViewController 以 UIKit 方式 present，
/// 讓 picker 的自我 dismiss 只影響它自己。
struct ContactPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelect: ([InviteeContact]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onSelect: onSelect)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
        context.coordinator.isPresented = $isPresented
        guard isPresented,
              uiViewController.presentedViewController == nil,
              !context.coordinator.isPickerVisible
        else { return }

        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.predicateForEnablingContact = NSPredicate(
            format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0"
        )
        context.coordinator.isPickerVisible = true
        uiViewController.present(picker, animated: true)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var isPresented: Binding<Bool>
        var isPickerVisible = false
        private let onSelect: ([InviteeContact]) -> Void

        init(
            isPresented: Binding<Bool>,
            onSelect: @escaping ([InviteeContact]) -> Void
        ) {
            self.isPresented = isPresented
            self.onSelect = onSelect
        }

        func contactPicker(
            _ picker: CNContactPickerViewController,
            didSelect contacts: [CNContact]
        ) {
            let invitees = contacts.map {
                InviteeContact(
                    contactIdentifier: $0.identifier,
                    displayName: CNContactFormatter.string(from: $0, style: .fullName)
                        ?? "未命名聯絡人"
                )
            }
            finishPresentation()
            onSelect(invitees)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            finishPresentation()
        }

        private func finishPresentation() {
            isPickerVisible = false
            isPresented.wrappedValue = false
        }
    }
}
