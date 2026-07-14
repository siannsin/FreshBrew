import XCTest
@testable import FreshBrew

@MainActor
final class AppWorkflowTests: XCTestCase {
    func testNotificationActionRouterHandlesOnlyUpdateAllAction() async {
        var calls = 0
        let router = NotificationActionRouter { calls += 1 }

        let ignored = await router.handle(actionIdentifier: "unrelated")
        let handled = await router.handle(
            actionIdentifier: NotificationService.updateAllActionIdentifier
        )

        XCTAssertFalse(ignored)
        XCTAssertTrue(handled)
        XCTAssertEqual(calls, 1)
    }

    func testSingleInstanceGuardIgnoresCurrentProcess() {
        XCTAssertFalse(SingleInstanceGuard.shouldTerminateNewInstance(
            currentProcessIdentifier: 10,
            runningProcessIdentifiers: [10]
        ))
        XCTAssertTrue(SingleInstanceGuard.shouldTerminateNewInstance(
            currentProcessIdentifier: 10,
            runningProcessIdentifiers: [9, 10]
        ))
    }
}
