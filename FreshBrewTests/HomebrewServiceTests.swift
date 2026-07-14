import Foundation
import XCTest
@testable import FreshBrew

final class HomebrewServiceTests: XCTestCase {
    func testCheckOutdatedRefreshesThenUsesGreedySetting() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(
                exitCode: 0,
                standardOutput: "firefox (1.0) != 2.0\n",
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let packages = try await service.checkOutdated(greedy: true)

        XCTAssertEqual(packages.map(\.name), ["firefox"])
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["update"],
            ["outdated", "--verbose", "--greedy"]
        ])
    }

    func testUpdatePreservesPartialSuccessAfterCommandFailure() async throws {
        let first = package(named: "first", kind: .formula)
        let second = package(named: "second", kind: .formula)
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 1,
                standardOutput: "==> Upgrading first\n",
                standardError: "second failed"
            ),
            CommandResult(
                exitCode: 0,
                standardOutput: "second (1.0) < 2.0\n",
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(
            packages: [first, second],
            greedy: false
        )

        XCTAssertEqual(result.completedPackages.map(\.name), ["first"])
        XCTAssertEqual(result.remainingPackages.map(\.name), ["second"])
        XCTAssertTrue(result.hasFailures)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["upgrade", "--formula", "first", "second"],
            ["outdated", "--verbose"]
        ])
    }

    func testUpdateForceReinstallsOnlyRefusedCandidateCasks() async throws {
        let package = package(named: "duckduckgo", kind: .cask)
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "Warning: The cask 'duckduckgo' cannot be upgraded as-is.",
                standardError: ""
            ),
            CommandResult(exitCode: 0, standardOutput: "reinstalled", standardError: ""),
            CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(packages: [package], greedy: true)

        XCTAssertEqual(result.completedPackages.map(\.name), ["duckduckgo"])
        XCTAssertFalse(result.hasFailures)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["upgrade", "--cask", "--greedy", "duckduckgo"],
            ["reinstall", "--cask", "--force", "duckduckgo"],
            ["outdated", "--verbose", "--greedy"]
        ])
    }

    func testUpdateUsesFreshBrewAskpassEnvironmentAndRemovesTemporaryFiles() async throws {
        let package = package(named: "firefox", kind: .cask)
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let service = makeService(runner: runner)

        _ = try await service.update(
            packages: [package],
            greedy: false,
            administratorPassword: "example-password"
        )

        let requests = await runner.recordedRequests()
        let askpassPath = try XCTUnwrap(requests.first?.environment["SUDO_ASKPASS"])
        XCTAssertTrue(URL(fileURLWithPath: askpassPath).lastPathComponent.hasPrefix("freshbrew-askpass-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: askpassPath))

        let environmentContainsPassword = requests.first?.environment.values.contains {
            $0.contains("example-password")
        } ?? true
        XCTAssertFalse(environmentContainsPassword)
    }

    func testCleanupUsesDeepPruneOnlyWhenRequested() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "clean", standardError: ""),
            CommandResult(exitCode: 0, standardOutput: "deep clean", standardError: "")
        ])
        let service = makeService(runner: runner)

        _ = try await service.cleanup(deep: false)
        _ = try await service.cleanup(deep: true)

        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["cleanup"],
            ["cleanup", "--prune=all"]
        ])
    }

    func testFailedCaskRecoveryRestoresStagedApplication() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationURL = temporaryDirectory.appendingPathComponent("Stats.app", isDirectory: true)
        let recoveryURL = temporaryDirectory.appendingPathComponent("FreshBrew/CaskRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 1, standardOutput: "", standardError: "reinstall failed")
        ])
        let service = makeService(runner: runner)

        do {
            _ = try await service.recoverConflictingCask(
                package(named: "stats", kind: .cask),
                applicationURL: applicationURL,
                greedy: true,
                recoveryStore: CaskRecoveryStore(rootDirectory: recoveryURL)
            )
            XCTFail("Expected recovery to fail")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: applicationURL.path))
        }
    }

    private func makeService(runner: StubCommandRunner) -> HomebrewService {
        HomebrewService(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            runner: runner,
            executableIsAvailable: { _ in true }
        )
    }

    private func package(named name: String, kind: HomebrewPackageKind) -> HomebrewPackage {
        HomebrewPackage(
            name: name,
            installedVersion: "1.0",
            availableVersion: "2.0",
            kind: kind
        )
    }
}

private actor StubCommandRunner: CommandRunning {
    enum StubError: Error {
        case missingResult
    }

    private var results: [CommandResult]
    private var requests: [CommandRequest] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(
        _ request: CommandRequest,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        requests.append(request)
        guard !results.isEmpty else { throw StubError.missingResult }
        let result = results.removeFirst()
        onOutput?(result.combinedOutput)
        return result
    }

    func recordedRequests() -> [CommandRequest] {
        requests
    }
}
