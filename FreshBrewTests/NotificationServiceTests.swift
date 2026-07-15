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

    func testUpdateCompletionContentIncludesCleanupOutcome() {
        let completed = NotificationService.updateCompletionContent(
            updatedCount: 2,
            cleanupOutcome: .completed
        )
        let failed = NotificationService.updateCompletionContent(
            updatedCount: 1,
            cleanupOutcome: .failed
        )
        let disabled = NotificationService.updateCompletionContent(
            updatedCount: 3,
            cleanupOutcome: nil
        )

        XCTAssertEqual(completed.body, "2 packages updated · Cleanup completed")
        XCTAssertEqual(failed.body, "1 package updated · Cleanup failed")
        XCTAssertEqual(disabled.body, "3 packages updated")
    }
}
