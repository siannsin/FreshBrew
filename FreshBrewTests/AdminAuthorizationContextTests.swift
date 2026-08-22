import Foundation
import XCTest
@testable import FreshBrew

final class AdminAuthorizationContextTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testBundledContextUsesExecutableHelperOnly() throws {
        let appBundleURL = temporaryDirectory.appendingPathComponent(
            "FreshBrew.app",
            isDirectory: true
        )
        let helperURL = appBundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(AdminAuthorizationContext.helperName)
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: helperURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o700]
        ))

        let context = try XCTUnwrap(AdminAuthorizationContext.bundled(
            appBundleURL: appBundleURL
        ))

        XCTAssertEqual(context.askpassExecutableURL, helperURL)
        XCTAssertEqual(context.environment, ["SUDO_ASKPASS": helperURL.path])
        XCTAssertNil(context.environment["SUDO_ASKPASS_REQUIRE"])
        let temporaryItems = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        )
        XCTAssertFalse(temporaryItems.contains { $0.hasPrefix("freshbrew-pw-") })
    }

    func testBundledContextRejectsMissingOrNonExecutableHelper() throws {
        let appBundleURL = temporaryDirectory.appendingPathComponent(
            "FreshBrew.app",
            isDirectory: true
        )
        XCTAssertNil(AdminAuthorizationContext.bundled(appBundleURL: appBundleURL))
    }

    func testConfirmedAskpassResponseWritesOnlyPasswordAndNewline() {
        let response = AskpassResponse.confirmed(password: "private-value")

        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(String(data: response.standardOutput, encoding: .utf8), "private-value\n")
    }

    func testCancelledAndEmptyAskpassResponsesWriteNothing() {
        XCTAssertEqual(AskpassResponse.cancelled.exitCode, 1)
        XCTAssertTrue(AskpassResponse.cancelled.standardOutput.isEmpty)
        XCTAssertEqual(AskpassResponse.confirmed(password: ""), .cancelled)
    }
}
