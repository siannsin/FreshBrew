import Foundation
import UserNotifications

@MainActor
final class NotificationActionRouter {
    private let updateAll: @MainActor () async -> Void
    private let viewRelease: @MainActor (String) -> Bool

    init(
        updateAll: @escaping @MainActor () async -> Void,
        viewRelease: @escaping @MainActor (String) -> Bool
    ) {
        self.updateAll = updateAll
        self.viewRelease = viewRelease
    }

    @discardableResult
    func handle(
        actionIdentifier: String,
        releasePageURL: String? = nil
    ) async -> Bool {
        if actionIdentifier == NotificationService.updateAllActionIdentifier {
            await updateAll()
            return true
        }

        let opensRelease = actionIdentifier == NotificationService.viewReleaseActionIdentifier
            || actionIdentifier == UNNotificationDefaultActionIdentifier
        guard opensRelease, let releasePageURL else { return false }
        return viewRelease(releasePageURL)
    }
}
