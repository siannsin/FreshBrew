import XCTest
@testable import FreshBrew

final class AppIdentityTests: XCTestCase {
    func testFreshBrewIdentity() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
            AppIdentity.bundleName
        )
        XCTAssertEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleIdentifier)
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            AppIdentity.displayName
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            AppIdentity.buildNumber
        )
    }
}
