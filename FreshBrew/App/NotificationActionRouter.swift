import Foundation

@MainActor
final class NotificationActionRouter {
    private let updateAll: @MainActor () async -> Void

    init(updateAll: @escaping @MainActor () async -> Void) {
        self.updateAll = updateAll
    }

    @discardableResult
    func handle(actionIdentifier: String) async -> Bool {
        guard actionIdentifier == NotificationService.updateAllActionIdentifier else {
            return false
        }
        await updateAll()
        return true
    }
}
