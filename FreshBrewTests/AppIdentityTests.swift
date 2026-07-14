import XCTest
@testable import FreshBrew

final class AppIdentityTests: XCTestCase {
    func testFreshBrewIdentity() {
        XCTAssertEqual(AppIdentity.displayName, "FreshBrew")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "net.siann.freshbrew")
        XCTAssertEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleIdentifier)
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            AppIdentity.displayName
        )
    }
}
