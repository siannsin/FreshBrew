import Foundation
import UserNotifications

@MainActor
final class NotificationActionRouter {
    private let updateAll: @MainActor (Set<String>?) async -> Void
    private let viewRelease: @MainActor (String) -> Bool
    private let restartApplication: @MainActor () -> Void

    init(
        updateAll: @escaping @MainActor (Set<String>?) async -> Void,
        viewRelease: @escaping @MainActor (String) -> Bool,
        restartApplication: @escaping @MainActor () -> Void
    ) {
        self.updateAll = updateAll
        self.viewRelease = viewRelease
        self.restartApplication = restartApplication
    }

    @discardableResult
    func handle(
        actionIdentifier: String,
        releasePageURL: String? = nil,
        packageIDs: Set<String>? = nil
    ) async -> Bool {
        if actionIdentifier == NotificationService.updateAllActionIdentifier {
            await updateAll(packageIDs)
            return true
        }

        if actionIdentifier == NotificationService.restartActionIdentifier {
            restartApplication()
            return true
        }

        let opensRelease = actionIdentifier == NotificationService.viewReleaseActionIdentifier
            || actionIdentifier == UNNotificationDefaultActionIdentifier
        guard opensRelease, let releasePageURL else { return false }
        return viewRelease(releasePageURL)
    }
}
