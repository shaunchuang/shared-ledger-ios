import CloudKit
import CoreData
import SwiftUI
import UIKit

struct CloudSharePayload: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
    let store: NSPersistentStore
    let title: String
}

struct CloudSharingView: UIViewControllerRepresentable {
    let payload: CloudSharePayload
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            title: payload.title,
            store: payload.store,
            onError: onError
        )
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
        private let store: NSPersistentStore
        private let onError: (String) -> Void
        private let persistence = PersistenceController.shared

        init(
            title: String,
            store: NSPersistentStore,
            onError: @escaping (String) -> Void
        ) {
            self.title = title
            self.store = store
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
                title: "無法儲存共享邀請",
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
                        title: "無法同步共享邀請",
                        error: error
                    )
                }
            }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            guard let share = csc.share else { return }
            persistence.container.purgeObjectsAndRecordsInZone(
                with: share.recordID.zoneID,
                in: store
            ) { [weak self] _, error in
                if let error {
                    self?.report(
                        title: "無法停止共享",
                        error: error
                    )
                }
            }
        }

        private func report(title: String, error: Error) {
            let message = "\(title)：\(error.localizedDescription)"
            DispatchQueue.main.async { [onError] in
                onError(message)
            }
        }
    }
}
