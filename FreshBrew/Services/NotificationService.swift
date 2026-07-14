import Foundation
import UserNotifications

protocol NotificationServing: Sendable {
    func requestAuthorization() async
    func postUpdatesAvailable(count: Int) async
    func postCheckFailure(message: String) async
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
}
