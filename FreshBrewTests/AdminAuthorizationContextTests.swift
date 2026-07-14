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

    func testContextUsesFreshBrewNamesAndRestrictivePermissions() throws {
        let context = try AdminAuthorizationContext.create(
            password: "private-value",
            directory: temporaryDirectory
        )
        defer { context.removeFiles() }

        XCTAssertTrue(context.passwordFileURL.lastPathComponent.hasPrefix("freshbrew-pw-"))
        XCTAssertTrue(context.askpassScriptURL.lastPathComponent.hasPrefix("freshbrew-askpass-"))
        XCTAssertEqual(context.environment["SUDO_ASKPASS"], context.askpassScriptURL.path)
        XCTAssertEqual(context.environment["SUDO_ASKPASS_REQUIRE"], "force")

        let passwordAttributes = try FileManager.default.attributesOfItem(
            atPath: context.passwordFileURL.path
        )
        let scriptAttributes = try FileManager.default.attributesOfItem(
            atPath: context.askpassScriptURL.path
        )
        XCTAssertEqual(passwordAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(scriptAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))

        let script = try String(contentsOf: context.askpassScriptURL, encoding: .utf8)
        XCTAssertFalse(script.contains("private-value"))
    }

    func testRemoveFilesDeletesCredentialArtifacts() throws {
        let context = try AdminAuthorizationContext.create(
            password: "private-value",
            directory: temporaryDirectory
        )

        context.removeFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.passwordFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.askpassScriptURL.path))
    }
}
