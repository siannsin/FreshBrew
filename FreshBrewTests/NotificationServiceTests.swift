import XCTest
@preconcurrency import UserNotifications
@testable import FreshBrew

final class NotificationServiceTests: XCTestCase {
    func testAvailableUpdateAlertsReplaceLegacyAlertsWithoutRemovingOtherTypes() async {
        let legacy = UNNotificationRequest(
            identifier: "legacy-updates", content: NotificationService.updatesContent(count: 2), trigger: nil
        )
        let unrelated = UNNotificationRequest(
            identifier: "failure", content: NotificationService.checkFailureContent(message: "test"), trigger: nil
        )
        let center = FakeNotificationCenter(
            delivered: [NotificationRequestValue(legacy), NotificationRequestValue(unrelated)],
            pending: [NotificationRequestValue(legacy)]
        )
        let service = NotificationService(center: center)
        let package = HomebrewPackage(name: "ripgrep", installedVersion: "1", availableVersion: "2", kind: .formula)

        await service.postUpdatesAvailable(packages: [package])
        await service.postUpdatesAvailable(packages: [package])

        let delivered = await center.deliveredRequests()
        XCTAssertEqual(delivered.map { $0.request.identifier }, ["failure", NotificationService.availableUpdatesRequestIdentifier])
        let added = await center.addedRequests()
        XCTAssertEqual(added.count, 2, "Unchanged results must still notify on each check")
        XCTAssertEqual(added.last?.request.content.userInfo[NotificationService.packageIDsUserInfoKey] as? [String], [package.id])
        let pending = await center.pendingRequests()
        XCTAssertTrue(pending.isEmpty)
    }

    func testEmptyResultsClearAvailableUpdateAlertsWithoutPostingAnother() async {
        let center = FakeNotificationCenter(delivered: [NotificationRequestValue(UNNotificationRequest(
            identifier: "old", content: NotificationService.updatesContent(count: 1), trigger: nil
        ))])
        let service = NotificationService(center: center)
        await service.postUpdatesAvailable(packages: [])

        let delivered = await center.deliveredRequests()
        let added = await center.addedRequests()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(added.isEmpty)
    }

    func testUpdatesContentUsesCountAndActionCategory() {
        let content = NotificationService.updatesContent(count: 2)

        XCTAssertEqual(content.title, AppIdentity.displayName)
        XCTAssertEqual(content.body, "2 Homebrew updates available")
        XCTAssertEqual(
            content.categoryIdentifier,
            NotificationService.updatesCategoryIdentifier
        )
    }

    func testCheckFailureContentIncludesMessage() {
        let content = NotificationService.checkFailureContent(message: "Network unavailable")

        XCTAssertEqual(content.title, AppIdentity.displayName)
        XCTAssertEqual(content.body, "Check failed · Network unavailable")
    }

    func testCleanupResultContentIncludesOperationAndFreedSpace() {
        let cleanup = CleanupResult(
            isDeepCleanup: false,
            output: "This operation has freed approximately 1.3GB of disk space.",
            completedAt: Date()
        )
        let deepCleanup = CleanupResult(
            isDeepCleanup: true,
            output: "This operation has freed approximately 3.5GB of disk space.",
            completedAt: Date()
        )

        let cleanupContent = NotificationService.cleanupResultContent(cleanup)
        let deepCleanupContent = NotificationService.cleanupResultContent(deepCleanup)

        XCTAssertEqual(cleanupContent.title, AppIdentity.displayName)
        XCTAssertEqual(cleanupContent.body, "Cleanup completed · 1.3GB freed")
        XCTAssertEqual(deepCleanupContent.title, AppIdentity.displayName)
        XCTAssertEqual(deepCleanupContent.body, "Deep cleanup completed · 3.5GB freed")
    }

    func testCleanupResultContentOmitsUnknownFreedSpace() {
        let result = CleanupResult(
            isDeepCleanup: false,
            output: "Pruned 0 symbolic links and 2 directories.",
            completedAt: Date()
        )

        let content = NotificationService.cleanupResultContent(result)

        XCTAssertEqual(content.title, AppIdentity.displayName)
        XCTAssertEqual(content.body, "Cleanup completed")
    }

    func testCleanupFailureContentIncludesOperationAndSafeReason() {
        let cleanupContent = NotificationService.cleanupFailureContent(
            deep: false,
            message: "Network unavailable. Check your connection and try again."
        )
        let deepCleanupContent = NotificationService.cleanupFailureContent(
            deep: true,
            message: "Deep Cleanup timed out after 5 minutes."
        )

        XCTAssertEqual(cleanupContent.title, AppIdentity.displayName)
        XCTAssertEqual(
            cleanupContent.body,
            "Cleanup failed · Network unavailable. Check your connection and try again."
        )
        XCTAssertEqual(deepCleanupContent.title, AppIdentity.displayName)
        XCTAssertEqual(
            deepCleanupContent.body,
            "Deep cleanup timed out after 5 minutes."
        )
    }

    func testApplicationUpdateContentIncludesReleaseActionAndURL() throws {
        let url = try XCTUnwrap(URL(
            string: "https://github.com/siannsin/FreshBrew/releases/tag/v0.2.0"
        ))
        let content = NotificationService.applicationUpdateContent(
            version: "0.2.0",
            releasePageURL: url
        )

        XCTAssertEqual(content.title, AppIdentity.displayName)
        XCTAssertEqual(content.body, "Version 0.2.0 is available")
        XCTAssertEqual(
            content.categoryIdentifier,
            NotificationService.applicationUpdateCategoryIdentifier
        )
        XCTAssertEqual(
            content.userInfo[NotificationService.releasePageURLUserInfoKey] as? String,
            url.absoluteString
        )
    }

    func testUpdateResultContentIncludesCleanupOutcome() {
        let completed = NotificationService.updateResultContent(
            updatedCount: 2,
            remainingUpdateCount: 0,
            hadFailures: false,
            newlyAvailableCount: 3,
            cleanupOutcome: .completed(freedSpace: "1.3GB")
        )
        let cleanupWithNoFreedSpace = NotificationService.updateResultContent(
            updatedCount: 2,
            remainingUpdateCount: 0,
            hadFailures: false,
            newlyAvailableCount: 0,
            cleanupOutcome: .completed(freedSpace: nil)
        )
        let cleanupFailed = NotificationService.updateResultContent(
            updatedCount: 1,
            remainingUpdateCount: 0,
            hadFailures: false,
            newlyAvailableCount: 1,
            cleanupOutcome: .failed
        )
        let disabled = NotificationService.updateResultContent(
            updatedCount: 3,
            remainingUpdateCount: 0,
            hadFailures: false,
            newlyAvailableCount: 0,
            cleanupOutcome: nil
        )

        XCTAssertEqual(completed.title, AppIdentity.displayName)
        XCTAssertEqual(
            completed.body,
            "2 packages updated · 3 new updates available · 1.3GB freed"
        )
        XCTAssertEqual(cleanupWithNoFreedSpace.title, AppIdentity.displayName)
        XCTAssertEqual(cleanupWithNoFreedSpace.body, "2 packages updated")
        XCTAssertEqual(cleanupFailed.title, AppIdentity.displayName)
        XCTAssertEqual(
            cleanupFailed.body,
            "1 package updated · 1 new update available · Cleanup failed"
        )
        XCTAssertEqual(disabled.title, AppIdentity.displayName)
        XCTAssertEqual(disabled.body, "3 packages updated")
    }

    func testUpdateResultContentDescribesPartialAndTotalFailures() {
        let partialFailure = NotificationService.updateResultContent(
            updatedCount: 3,
            remainingUpdateCount: 3,
            hadFailures: true,
            newlyAvailableCount: 1,
            cleanupOutcome: nil
        )
        let totalFailure = NotificationService.updateResultContent(
            updatedCount: 0,
            remainingUpdateCount: 1,
            hadFailures: true,
            newlyAvailableCount: 0,
            cleanupOutcome: nil
        )

        XCTAssertEqual(partialFailure.title, AppIdentity.displayName)
        XCTAssertEqual(
            partialFailure.body,
            "3 packages updated · Homebrew reported issues"
        )
        XCTAssertEqual(totalFailure.title, AppIdentity.displayName)
        XCTAssertEqual(
            totalFailure.body,
            "Update failed · 1 package still needs an update"
        )
    }

    func testAllVerifiedUpdatesWithErrorsReportHomebrewIssues() {
        let content = NotificationService.updateResultContent(
            updatedCount: 8,
            remainingUpdateCount: 0,
            hadFailures: true,
            newlyAvailableCount: 0,
            cleanupOutcome: nil
        )

        XCTAssertEqual(content.body, "8 packages updated · Homebrew reported issues")
    }

    func testUpdateResultContentDescribesUnavailableVerification() {
        let partialResult = NotificationService.updateResultContent(
            updatedCount: 1,
            remainingUpdateCount: 2,
            hadFailures: true,
            newlyAvailableCount: 0,
            cleanupOutcome: nil,
            verificationUnavailable: true
        )
        let failedResult = NotificationService.updateResultContent(
            updatedCount: 0,
            remainingUpdateCount: 2,
            hadFailures: true,
            newlyAvailableCount: 0,
            cleanupOutcome: nil,
            verificationUnavailable: true
        )

        XCTAssertEqual(
            partialResult.body,
            "1 package updated · Remaining updates couldn’t be verified"
        )
        XCTAssertEqual(
            failedResult.body,
            "Update failed · Remaining updates couldn’t be verified"
        )
    }

    func testUpdateResultContentDescribesRequiredXcodeSetup() {
        let content = NotificationService.updateResultContent(
            updatedCount: 0,
            remainingUpdateCount: 2,
            hadFailures: true,
            newlyAvailableCount: 0,
            cleanupOutcome: nil,
            verificationUnavailable: true,
            xcodeLicenseRequired: true
        )

        XCTAssertEqual(content.body, "Update failed · Complete Xcode setup and try again")
    }

    func testUpdateResultContentIncludesRestartActionAfterSelfUpdate() {
        let content = NotificationService.updateResultContent(
            updatedCount: 4,
            remainingUpdateCount: 0,
            hadFailures: false,
            newlyAvailableCount: 0,
            cleanupOutcome: .completed(freedSpace: "1.3GB"),
            restartRequired: true
        )

        XCTAssertEqual(
            content.body,
            "4 packages updated · 1.3GB freed · Restart \(AppIdentity.displayName) to finish"
        )
        XCTAssertEqual(
            content.categoryIdentifier,
            NotificationService.restartCategoryIdentifier
        )
    }

    func testCleanupResultExtractsHomebrewFreedSpace() {
        let result = CleanupResult(
            isDeepCleanup: false,
            output: "==> This operation has freed approximately 1.3GB of disk space.",
            completedAt: Date()
        )
        let noSpaceReported = CleanupResult(
            isDeepCleanup: false,
            output: "Pruned 0 symbolic links and 2 directories.",
            completedAt: Date()
        )
        let zeroSpaceFreed = CleanupResult(
            isDeepCleanup: false,
            output: "This operation has freed approximately 0B of disk space.",
            completedAt: Date()
        )

        XCTAssertEqual(result.freedSpaceDescription, "1.3GB")
        XCTAssertNil(noSpaceReported.freedSpaceDescription)
        XCTAssertNil(zeroSpaceFreed.freedSpaceDescription)
    }
}

private actor FakeNotificationCenter: NotificationCenterServing {
    private var delivered: [NotificationRequestValue]
    private var pending: [NotificationRequestValue]
    private var added: [NotificationRequestValue] = []

    init(delivered: [NotificationRequestValue] = [], pending: [NotificationRequestValue] = []) {
        self.delivered = delivered
        self.pending = pending
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: NotificationRequestValue) async throws {
        added.append(request)
        delivered.append(request)
    }
    func deliveredRequests() async -> [NotificationRequestValue] { delivered }
    func pendingRequests() async -> [NotificationRequestValue] { pending }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        delivered.removeAll { identifiers.contains($0.request.identifier) }
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        pending.removeAll { identifiers.contains($0.request.identifier) }
    }
    func setNotificationCategories(_ categories: NotificationCategoriesValue) async {}
    func addedRequests() -> [NotificationRequestValue] { added }
}
