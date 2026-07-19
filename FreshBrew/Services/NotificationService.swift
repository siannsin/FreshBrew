import Foundation
import UserNotifications

enum UpdateCleanupOutcome: Sendable, Equatable {
    case completed(freedSpace: String?)
    case failed
}

protocol NotificationServing: Sendable {
    func requestAuthorization() async
    func postUpdatesAvailable(count: Int) async
    func postCheckFailure(message: String) async
    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?
    ) async
}

actor NotificationService: NotificationServing {
    static let updatesCategoryIdentifier = "net.siann.freshbrew.updates-available"
    static let updateAllActionIdentifier = "net.siann.freshbrew.update-all"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async {
        registerCategories()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func postUpdatesAvailable(count: Int) async {
        guard count > 0 else { return }
        registerCategories()
        let request = UNNotificationRequest(
            identifier: "net.siann.freshbrew.updates-\(UUID().uuidString)",
            content: Self.updatesContent(count: count),
            trigger: nil
        )
        try? await center.add(request)
    }

    func postCheckFailure(message: String) async {
        let request = UNNotificationRequest(
            identifier: "net.siann.freshbrew.check-failure-\(UUID().uuidString)",
            content: Self.checkFailureContent(message: message),
            trigger: nil
        )
        try? await center.add(request)
    }

    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?
    ) async {
        guard updatedCount > 0 || hadFailures else { return }
        let request = UNNotificationRequest(
            identifier: "net.siann.freshbrew.update-result-\(UUID().uuidString)",
            content: Self.updateResultContent(
                updatedCount: updatedCount,
                remainingUpdateCount: remainingUpdateCount,
                hadFailures: hadFailures,
                newlyAvailableCount: newlyAvailableCount,
                cleanupOutcome: cleanupOutcome
            ),
            trigger: nil
        )
        try? await center.add(request)
    }

    nonisolated static func updatesContent(count: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        content.body = "\(count) Homebrew update\(count == 1 ? "" : "s") available"
        content.sound = .default
        content.categoryIdentifier = updatesCategoryIdentifier
        return content
    }

    nonisolated static func checkFailureContent(message: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "FreshBrew check failed"
        content.body = message
        content.sound = .default
        return content
    }

    nonisolated static func updateResultContent(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        var details: [String] = []
        if updatedCount > 0 {
            let noun = updatedCount == 1 ? "package" : "packages"
            details.append("\(updatedCount) \(noun) updated")
        } else {
            details.append("Update failed")
        }

        if hadFailures {
            if remainingUpdateCount == 1 {
                let subject = updatedCount > 0 ? "1" : "1 package"
                details.append("\(subject) still needs an update")
            } else if remainingUpdateCount > 1 {
                let subject = updatedCount > 0
                    ? "\(remainingUpdateCount)"
                    : "\(remainingUpdateCount) packages"
                details.append("\(subject) still need updates")
            } else {
                details.append("Some update operations failed")
            }
        } else if newlyAvailableCount > 0 {
            let updateNoun = newlyAvailableCount == 1 ? "update" : "updates"
            details.append("\(newlyAvailableCount) new \(updateNoun) available")
        }
        switch cleanupOutcome {
        case let .completed(freedSpace):
            if let freedSpace {
                details.append("\(freedSpace) freed")
            }
        case .failed:
            details.append("Cleanup failed")
        case nil:
            break
        }
        content.body = details.joined(separator: " · ")
        content.sound = .default
        return content
    }

    private func registerCategories() {
        let updateAction = UNNotificationAction(
            identifier: Self.updateAllActionIdentifier,
            title: "Update All"
        )
        let category = UNNotificationCategory(
            identifier: Self.updatesCategoryIdentifier,
            actions: [updateAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }
}

actor NoopNotificationService: NotificationServing {
    func requestAuthorization() async {}
    func postUpdatesAvailable(count: Int) async {}
    func postCheckFailure(message: String) async {}
    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?
    ) async {}
}
