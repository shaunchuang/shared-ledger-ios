import CloudKit
import SwiftUI
import UIKit

struct CloudSharePayload: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
    let title: String
}

struct CloudSharingView: UIViewControllerRepresentable {
    let payload: CloudSharePayload

    func makeCoordinator() -> Coordinator {
        Coordinator(title: payload.title)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: payload.share,
            container: payload.container
        )
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UICloudSharingController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        private let title: String
        private let persistence = PersistenceController.shared

        init(title: String) {
            self.title = title
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            title
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            assertionFailure("Unable to save CloudKit share: \(error.localizedDescription)")
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            guard let share = csc.share else { return }
            persistence.container.persistUpdatedShare(
                share,
                in: persistence.privateStore
            ) { _, error in
                if let error {
                    assertionFailure(
                        "Unable to persist CloudKit share: \(error.localizedDescription)"
                    )
                }
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            guard let share = csc.share else { return }
            persistence.container.purgeObjectsAndRecordsInZone(
                with: share.recordID.zoneID,
                in: persistence.privateStore
            ) { _, error in
                if let error {
                    assertionFailure(
                        "Unable to stop CloudKit sharing: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
}
