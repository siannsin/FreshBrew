import Foundation
import XCTest
@testable import FreshBrew

final class CaskRecoveryStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var recoveryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        recoveryDirectory = temporaryDirectory
            .appendingPathComponent("FreshBrew/CaskRecovery", isDirectory: true)
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

    func testStageAndRestoreApplication() throws {
        let applicationURL = temporaryDirectory.appendingPathComponent("Stats.app", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        let store = CaskRecoveryStore(rootDirectory: recoveryDirectory)

        let backup = try store.stageApplication(at: applicationURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.backupURL.path))
        XCTAssertTrue(backup.backupURL.lastPathComponent.hasPrefix("Stats-"))

        try store.restore(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: applicationURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.backupURL.path))
    }

    func testStaleBackupCleanupKeepsRecentDirectories() throws {
        let store = CaskRecoveryStore(rootDirectory: recoveryDirectory)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let staleURL = recoveryDirectory.appendingPathComponent("stale.app", isDirectory: true)
        let recentURL = recoveryDirectory.appendingPathComponent("recent.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: staleURL.path
        )

        let removed = try store.removeBackups(olderThan: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(removed.map(\.lastPathComponent), ["stale.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
    }
}
