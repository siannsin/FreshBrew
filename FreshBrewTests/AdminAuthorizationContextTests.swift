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

    func testEnvironmentIncludesSessionContextOnlyWhenProvided() {
        let helperURL = URL(fileURLWithPath: "/tmp/FreshBrewAskpass")
        let contextURL = URL(fileURLWithPath: "/tmp/package-context")
        let context = AdminAuthorizationContext(askpassExecutableURL: helperURL)

        XCTAssertEqual(
            AskpassPackageContextSession.environmentKey,
            "HOMEBREW_FRESHBREW_PACKAGE_CONTEXT"
        )
        XCTAssertEqual(
            context.environment(packageContextFileURL: contextURL),
            [
                "SUDO_ASKPASS": helperURL.path,
                AskpassPackageContextSession.environmentKey: contextURL.path
            ]
        )
    }

    func testPackageContextUsesRestrictivePermissionsAndClearsAfterSession() throws {
        let session = try AskpassPackageContextSession(
            selectedPackageIDs: ["cask:omnissa-horizon-client"],
            parentDirectoryURL: temporaryDirectory
        )
        let directoryURL = session.contextFileURL.deletingLastPathComponent()

        XCTAssertTrue(session.setCurrentPackage(id: "cask:omnissa-horizon-client"))
        XCTAssertEqual(
            AskpassPackageContextSession.currentPackageName(
                environment: [
                    AskpassPackageContextSession.environmentKey: session.contextFileURL.path
                ]
            ),
            "omnissa-horizon-client"
        )

        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: session.contextFileURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directoryURL.path
        )
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)

        session.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
    }

    func testPackageContextRejectsUnknownPackageAndFallsBackToGenericPrompt() throws {
        let session = try AskpassPackageContextSession(
            selectedPackageIDs: ["formula:ripgrep", "cask:chatgpt"],
            parentDirectoryURL: temporaryDirectory
        )

        XCTAssertTrue(session.setCurrentPackage(id: "formula:ripgrep"))
        XCTAssertFalse(session.setCurrentPackage(id: "cask:unknown-package"))
        XCTAssertNil(AskpassPackageContextSession.currentPackageName(
            environment: [
                AskpassPackageContextSession.environmentKey: session.contextFileURL.path
            ]
        ))
    }

    func testPackageContextCanChangeAndRepeatedReadsKeepCurrentPackage() throws {
        let session = try AskpassPackageContextSession(
            selectedPackageIDs: ["formula:ripgrep", "cask:chatgpt"],
            parentDirectoryURL: temporaryDirectory
        )
        let environment = [
            AskpassPackageContextSession.environmentKey: session.contextFileURL.path
        ]

        XCTAssertTrue(session.setCurrentPackage(id: "formula:ripgrep"))
        XCTAssertEqual(
            AskpassPackageContextSession.currentPackageName(environment: environment),
            "ripgrep"
        )
        XCTAssertEqual(
            AskpassPackageContextSession.currentPackageName(environment: environment),
            "ripgrep"
        )

        XCTAssertTrue(session.setCurrentPackage(id: "cask:chatgpt"))
        XCTAssertEqual(
            AskpassPackageContextSession.currentPackageName(environment: environment),
            "chatgpt"
        )
    }

    func testPromptContentShowsKnownPackageOrGenericFallback() {
        XCTAssertEqual(
            AskpassPromptContent.informativeText(packageName: "omnissa-horizon-client"),
            "Enter your login password to continue updating:\n\nomnissa-horizon-client"
        )
        XCTAssertEqual(
            AskpassPromptContent.informativeText(packageName: nil),
            "Enter your login password to update."
        )
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
