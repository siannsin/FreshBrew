import Foundation
@preconcurrency import UserNotifications

enum UpdateCleanupOutcome: Sendable, Equatable {
    case completed(freedSpace: String?)
    case failed
}

protocol NotificationServing: Sendable {
    func requestAuthorization() async
    func postUpdatesAvailable(packages: [HomebrewPackage]) async
    func clearUpdatesAvailable() async
    func postCheckFailure(message: String) async
    func postCleanupResult(_ result: CleanupResult) async
    func postCleanupFailure(deep: Bool, message: String) async
    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool,
        xcodeLicenseRequired: Bool,
        restartRequired: Bool
    ) async
}

// UserNotifications exposes immutable request/category objects without Sendable
// annotations. Keep their cross-actor transport confined to these value wrappers.
struct NotificationRequestValue: @unchecked Sendable {
    let request: UNNotificationRequest
    init(_ request: UNNotificationRequest) { self.request = request }
}

struct NotificationCategoriesValue: @unchecked Sendable {
    let categories: Set<UNNotificationCategory>
}

protocol NotificationCenterServing: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: NotificationRequestValue) async throws
    func deliveredRequests() async -> [NotificationRequestValue]
    func pendingRequests() async -> [NotificationRequestValue]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
    func setNotificationCategories(_ categories: NotificationCategoriesValue) async
}

actor SystemNotificationCenter: NotificationCenterServing {
    private let center = UNUserNotificationCenter.current()
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }
    func add(_ request: NotificationRequestValue) async throws { try await center.add(request.request) }
    func deliveredRequests() async -> [NotificationRequestValue] {
        await center.deliveredNotifications().map { NotificationRequestValue($0.request) }
    }
    func pendingRequests() async -> [NotificationRequestValue] {
        await center.pendingNotificationRequests().map { NotificationRequestValue($0) }
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func setNotificationCategories(_ categories: NotificationCategoriesValue) async {
        center.setNotificationCategories(categories.categories)
    }
}

protocol ApplicationUpdateNotificationServing: Sendable {
    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async
}

actor NotificationService: NotificationServing, ApplicationUpdateNotificationServing {
    static let updatesCategoryIdentifier = identifier("updates-available")
    static let updateAllActionIdentifier = identifier("update-all")
    static let applicationUpdateCategoryIdentifier = identifier("application-update")
    static let viewReleaseActionIdentifier = identifier("view-release")
    static let restartCategoryIdentifier = identifier("restart-required")
    static let restartActionIdentifier = identifier("restart")
    static let releasePageURLUserInfoKey = "releasePageURL"
    static let packageIDsUserInfoKey = "packageIDs"
    static let availableUpdatesRequestIdentifier = identifier("available-updates")

    private let center: any NotificationCenterServing

    init(center: any NotificationCenterServing = SystemNotificationCenter()) {
        self.center = center
    }

    func requestAuthorization() async {
        await registerCategories()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func postUpdatesAvailable(packages: [HomebrewPackage]) async {
        await clearUpdatesAvailable()
        guard !packages.isEmpty else { return }
        await registerCategories()
        let content = Self.updatesContent(count: packages.count)
        content.userInfo = [Self.packageIDsUserInfoKey: packages.map(\.id)]
        let request = UNNotificationRequest(
            identifier: Self.availableUpdatesRequestIdentifier,
            content: content,
            trigger: nil
        )
        try? await center.add(NotificationRequestValue(request))
    }

    func clearUpdatesAvailable() async {
        let delivered = await center.deliveredRequests()
        let pending = await center.pendingRequests()
        // Category matching also removes alerts created by earlier versions.
        let deliveredIDs = delivered.filter {
            $0.request.content.categoryIdentifier == Self.updatesCategoryIdentifier
        }.map { $0.request.identifier }
        let pendingIDs = pending.filter {
            $0.request.content.categoryIdentifier == Self.updatesCategoryIdentifier
        }.map { $0.request.identifier }
        await center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
        await center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
    }

    func postCheckFailure(message: String) async {
        let request = UNNotificationRequest(
            identifier: Self.identifier("check-failure-\(UUID().uuidString)"),
            content: Self.checkFailureContent(message: message),
            trigger: nil
        )
        try? await center.add(NotificationRequestValue(request))
    }

    func postCleanupResult(_ result: CleanupResult) async {
        let request = UNNotificationRequest(
            identifier: Self.identifier("cleanup-result-\(UUID().uuidString)"),
            content: Self.cleanupResultContent(result),
            trigger: nil
        )
        try? await center.add(NotificationRequestValue(request))
    }

    func postCleanupFailure(deep: Bool, message: String) async {
        let request = UNNotificationRequest(
            identifier: Self.identifier("cleanup-failure-\(UUID().uuidString)"),
            content: Self.cleanupFailureContent(deep: deep, message: message),
            trigger: nil
        )
        try? await center.add(NotificationRequestValue(request))
    }

    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool,
        xcodeLicenseRequired: Bool,
        restartRequired: Bool
    ) async {
        guard updatedCount > 0 || hadFailures else { return }
        if restartRequired {
            await registerCategories()
        }
        let request = UNNotificationRequest(
            identifier: Self.identifier("update-result-\(UUID().uuidString)"),
            content: Self.updateResultContent(
                updatedCount: updatedCount,
                remainingUpdateCount: remainingUpdateCount,
                hadFailures: hadFailures,
                newlyAvailableCount: newlyAvailableCount,
                cleanupOutcome: cleanupOutcome,
                verificationUnavailable: verificationUnavailable,
                xcodeLicenseRequired: xcodeLicenseRequired,
                restartRequired: restartRequired
            ),
            trigger: nil
        )
        try? await center.add(NotificationRequestValue(request))
    }

    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async {
        await registerCategories()
        let request = UNNotificationRequest(
            identifier: Self.identifier("application-update-\(version)"),
            content: Self.applicationUpdateContent(
                version: version,
                releasePageURL: releasePageURL
            ),
            trigger: nil
        )
        try? await center.add(NotificationRequestValue(request))
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
        content.title = AppIdentity.displayName
        content.body = "Check failed · \(message)"
        content.sound = .default
        return content
    }

    nonisolated static func cleanupResultContent(
        _ result: CleanupResult
    ) -> UNMutableNotificationContent {
        let operation = result.isDeepCleanup ? "Deep cleanup" : "Cleanup"
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
        let operation = deep ? "Deep cleanup" : "Cleanup"
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        if let prefix = message.range(of: operation, options: [.anchored, .caseInsensitive]) {
            content.body = operation + message[prefix.upperBound...]
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
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool = false,
        xcodeLicenseRequired: Bool = false,
        restartRequired: Bool = false
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = AppIdentity.displayName
        var details: [String] = []
        if updatedCount > 0 {
            let noun = updatedCount == 1 ? "package" : "packages"
            details.append("\(updatedCount) \(noun) updated")
        } else {
            details.append("Update failed")
        }

        if xcodeLicenseRequired {
            details.append("Complete Xcode setup and try again")
        } else if verificationUnavailable {
            details.append("Remaining updates couldn’t be verified")
        } else if hadFailures {
            if updatedCount > 0 {
                details.append("Homebrew reported issues")
            } else if remainingUpdateCount == 1 {
                details.append("1 package still needs an update")
            } else if remainingUpdateCount > 1 {
                details.append("\(remainingUpdateCount) packages still need updates")
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
        if restartRequired {
            details.append("Restart \(AppIdentity.displayName) to finish")
            content.categoryIdentifier = restartCategoryIdentifier
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

    private func registerCategories() async {
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
        let restartAction = UNNotificationAction(
            identifier: Self.restartActionIdentifier,
            title: "Restart \(AppIdentity.displayName)"
        )
        let restartCategory = UNNotificationCategory(
            identifier: Self.restartCategoryIdentifier,
            actions: [restartAction],
            intentIdentifiers: []
        )
        await center.setNotificationCategories(NotificationCategoriesValue(categories: [
            category,
            applicationUpdateCategory,
            restartCategory
        ]))
    }

    nonisolated private static func identifier(_ suffix: String) -> String {
        "\(AppIdentity.bundleIdentifier).\(suffix)"
    }
}

actor NoopNotificationService: NotificationServing {
    func requestAuthorization() async {}
    func postUpdatesAvailable(packages: [HomebrewPackage]) async {}
    func clearUpdatesAvailable() async {}
    func postCheckFailure(message: String) async {}
    func postCleanupResult(_ result: CleanupResult) async {}
    func postCleanupFailure(deep: Bool, message: String) async {}
    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool,
        xcodeLicenseRequired: Bool,
        restartRequired: Bool
    ) async {}
}

actor NoopApplicationUpdateNotificationService: ApplicationUpdateNotificationServing {
    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async {}
}
