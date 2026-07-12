import Contacts
import ContactsUI
import SwiftUI

struct ContactPicker: UIViewControllerRepresentable {
    let onSelect: ([InviteeContact]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.predicateForEnablingContact = NSPredicate(
            format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0"
        )
        return picker
    }

    func updateUIViewController(
        _ uiViewController: CNContactPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onSelect: ([InviteeContact]) -> Void

        init(onSelect: @escaping ([InviteeContact]) -> Void) {
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
            onSelect(invitees)
        }
    }
}
