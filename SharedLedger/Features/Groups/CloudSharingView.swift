import CloudKit
import CoreData
import SwiftUI
import UIKit

struct CloudSharePayload: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
    let store: NSPersistentStore
    let group: LedgerGroup
    let title: String
}

struct CloudSharingView: UIViewControllerRepresentable {
    let payload: CloudSharePayload
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            title: payload.title,
            store: payload.store,
            group: payload.group,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: payload.share,
            container: payload.container
        )
        controller.delegate = context.coordinator
        controller.availablePermissions = [
            .allowPrivate,
            .allowReadOnly,
            .allowReadWrite
        ]
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UICloudSharingController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let title: String
        private let store: NSPersistentStore
        private let group: LedgerGroup
        private let onError: (String) -> Void
        private let persistence = PersistenceController.shared

        init(
            title: String,
            store: NSPersistentStore,
            group: LedgerGroup,
            onError: @escaping (String) -> Void
        ) {
            self.title = title
            self.store = store
            self.group = group
            self.onError = onError
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            title
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            report(
                title: .groupShareErrorSave,
                error: error
            )
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            guard let share = csc.share else { return }
            persistence.container.persistUpdatedShare(
                share,
                in: store
            ) { [weak self] _, error in
                if let error {
                    self?.report(
                        title: .groupShareErrorSync,
                        error: error
                    )
                }
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            // This delegate callback is the owner stopping the entire CKShare.
            // Do not purge the record zone here: purgeObjectsAndRecordsInZone
            // also deletes the owner's managed object graph. iOS 17 already
            // lets NSPersistentCloudKitContainer observe system sharing UI
            // changes and reconcile its share metadata automatically.
            Task { @MainActor [weak self] in
                self?.clearShareLocalParticipantMappings()
            }
        }

        @MainActor
        private func clearShareLocalParticipantMappings() {
            let context = persistence.container.viewContext
            let members = group.members as? Set<Member> ?? []
            let mappedMembers = members.filter { $0.cloudParticipantID != nil }
            guard !mappedMembers.isEmpty else { return }

            for member in mappedMembers {
                member.cloudParticipantID = nil
            }
            group.updatedAt = Date()

            do {
                try context.save()
            } catch {
                context.rollback()
                report(
                    title: .groupShareErrorStopped,
                    error: error
                )
            }
        }

        private func report(title: LedgerStringKey, error: Error) {
            // 錯誤本身還是系統或資料層給的字串，只有前半句是文案。
            let message = LedgerStringKey.groupShareErrorFormat.string(
                arguments: [title.string(), error.localizedDescription]
            )
            DispatchQueue.main.async { [onError] in
                onError(message)
            }
        }
    }
}
