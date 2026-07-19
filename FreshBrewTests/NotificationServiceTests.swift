import XCTest
@testable import FreshBrew

final class NotificationServiceTests: XCTestCase {
    func testUpdatesContentUsesCountAndActionCategory() {
        let content = NotificationService.updatesContent(count: 2)

        XCTAssertEqual(content.title, "FreshBrew")
        XCTAssertEqual(content.body, "2 Homebrew updates available")
        XCTAssertEqual(
            content.categoryIdentifier,
            NotificationService.updatesCategoryIdentifier
        )
    }

    func testCheckFailureContentIncludesMessage() {
        let content = NotificationService.checkFailureContent(message: "Network unavailable")

        XCTAssertEqual(content.title, "FreshBrew check failed")
        XCTAssertEqual(content.body, "Network unavailable")
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

        XCTAssertEqual(completed.title, "")
        XCTAssertEqual(
            completed.body,
            "2 packages updated · 3 new updates available · 1.3GB freed"
        )
        XCTAssertEqual(cleanupWithNoFreedSpace.title, "")
        XCTAssertEqual(cleanupWithNoFreedSpace.body, "2 packages updated")
        XCTAssertEqual(cleanupFailed.title, "")
        XCTAssertEqual(
            cleanupFailed.body,
            "1 package updated · 1 new update available · Cleanup failed"
        )
        XCTAssertEqual(disabled.title, "")
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

        XCTAssertEqual(partialFailure.title, "")
        XCTAssertEqual(
            partialFailure.body,
            "3 packages updated · 3 still need updates"
        )
        XCTAssertEqual(totalFailure.title, "")
        XCTAssertEqual(
            totalFailure.body,
            "Update failed · 1 package still needs an update"
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
