import Foundation
@preconcurrency import UserNotifications

enum UpdateCleanupOutcome: Sendable, Equatable {
    case completed(freedSpace: String?)
    case failed
}

protocol NotificationServing: Sendable {
    func requestAuthorization() async
    func postUpdatesAvailable(count: Int) async
    func postCheckFailure(message: String) async
    func postCleanupResult(_ result: CleanupResult) async
    func postCleanupFailure(deep: Bool, message: String) async
    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?
    ) async
}

protocol ApplicationUpdateNotificationServing: Sendable {
    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async
}

actor NotificationService: NotificationServing, ApplicationUpdateNotificationServing {
    static let updatesCategoryIdentifier = "net.siann.freshbrew.updates-available"
    static let updateAllActionIdentifier = "net.siann.freshbrew.update-all"
    static let applicationUpdateCategoryIdentifier = "net.siann.freshbrew.application-update"
    static let viewReleaseActionIdentifier = "net.siann.freshbrew.view-release"
    static let releasePageURLUserInfoKey = "releasePageURL"

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

    func postCleanupResult(_ result: CleanupResult) async {
        let request = UNNotificationRequest(
            identifier: "net.siann.freshbrew.cleanup-result-\(UUID().uuidString)",
            content: Self.cleanupResultContent(result),
            trigger: nil
        )
        try? await center.add(request)
    }

    func postCleanupFailure(deep: Bool, message: String) async {
        let request = UNNotificationRequest(
            identifier: "net.siann.freshbrew.cleanup-failure-\(UUID().uuidString)",
            content: Self.cleanupFailureContent(deep: deep, message: message),
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

    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async {
        registerCategories()
        let request = UNNotificationRequest(
            identifier: "net.siann.freshbrew.application-update-\(version)",
            content: Self.applicationUpdateContent(
                version: version,
                releasePageURL: releasePageURL
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

    nonisolated static func cleanupResultContent(
        _ result: CleanupResult
    ) -> UNMutableNotificationContent {
        let operation = result.isDeepCleanup ? "Deep Cleanup" : "Cleanup"
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        content.body = [
            "\(operation) completed",
            result.freedSpaceDescription.map { "\($0) freed" }
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        content.sound = .default
        return content
    }

    nonisolated static func cleanupFailureContent(
        deep: Bool,
        message: String
    ) -> UNMutableNotificationContent {
        let operation = deep ? "Deep Cleanup" : "Cleanup"
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        if message.range(of: operation, options: [.anchored, .caseInsensitive]) != nil {
            content.body = message
        } else {
            content.body = "\(operation) failed · \(message)"
        }
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

    nonisolated static func applicationUpdateContent(
        version: String,
        releasePageURL: URL
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        content.body = "Version \(version) is available"
        content.sound = .default
        content.categoryIdentifier = applicationUpdateCategoryIdentifier
        content.userInfo = [releasePageURLUserInfoKey: releasePageURL.absoluteString]
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
        let viewReleaseAction = UNNotificationAction(
            identifier: Self.viewReleaseActionIdentifier,
            title: "View Release"
        )
        let applicationUpdateCategory = UNNotificationCategory(
            identifier: Self.applicationUpdateCategoryIdentifier,
            actions: [viewReleaseAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category, applicationUpdateCategory])
    }
}

actor NoopNotificationService: NotificationServing {
    func requestAuthorization() async {}
    func postUpdatesAvailable(count: Int) async {}
    func postCheckFailure(message: String) async {}
    func postCleanupResult(_ result: CleanupResult) async {}
    func postCleanupFailure(deep: Bool, message: String) async {}
    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?
    ) async {}
}

actor NoopApplicationUpdateNotificationService: ApplicationUpdateNotificationServing {
    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async {}
}
