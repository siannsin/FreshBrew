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
}
