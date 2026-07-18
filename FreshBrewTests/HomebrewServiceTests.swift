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
        XCTAssertEqual(requests.map(\.timeoutPolicy), [
            HomebrewService.metadataTimeoutPolicy,
            HomebrewService.outdatedTimeoutPolicy
        ])
    }

    func testCheckOutdatedFailsBeforeRunningHomebrewWhenNetworkIsUnavailable() async throws {
        let runner = StubCommandRunner(results: [])
        let service = makeService(runner: runner, networkIsAvailable: false)

        do {
            _ = try await service.checkOutdated(greedy: false)
            XCTFail("Expected the network preflight to fail")
        } catch let error as HomebrewError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        let requests = await runner.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
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
        XCTAssertEqual(requests.map(\.timeoutPolicy), [
            HomebrewService.packageTimeoutPolicy,
            HomebrewService.outdatedTimeoutPolicy
        ])
    }

    func testUpdatePreservesCommandFailureWhenVerificationReportsNoUpdates() async throws {
        let package = package(named: "chatgpt", kind: .cask)
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 1,
                standardOutput: "==> Upgrading Cask chatgpt\n",
                standardError: "installer reported an error"
            ),
            CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(
            packages: [package],
            greedy: true
        )

        XCTAssertEqual(result.completedPackages.map(\.name), ["chatgpt"])
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(result.failures.first?.operation, "upgrade casks")
        XCTAssertTrue(result.failures.first?.output.contains("installer reported an error") == true)
    }

    func testUpdateRecordsTimeoutAndStillVerifiesPartialResults() async throws {
        let package = package(named: "large-cask", kind: .cask)
        let runner = StubCommandRunner(responses: [
            .timeout(CommandTimeoutError(
                reason: .inactivity,
                limit: 300,
                output: "download stalled"
            )),
            .result(CommandResult(
                exitCode: 0,
                standardOutput: "large-cask (1.0) != 2.0\n",
                standardError: ""
            ))
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(packages: [package], greedy: true)

        XCTAssertTrue(result.completedPackages.isEmpty)
        XCTAssertEqual(result.remainingPackages.map(\.name), ["large-cask"])
        XCTAssertEqual(result.failures.first?.kind, .timeout)
        XCTAssertEqual(result.failures.first?.operation, "upgrade casks")
        XCTAssertTrue(result.failures.first?.output.contains("download stalled") == true)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["upgrade", "--cask", "--greedy", "large-cask"],
            ["outdated", "--verbose", "--greedy"]
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
        XCTAssertEqual(
            requests.map(\.timeoutPolicy),
            [HomebrewService.cleanupTimeoutPolicy, HomebrewService.cleanupTimeoutPolicy]
        )
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

    private func makeService(
        runner: StubCommandRunner,
        networkIsAvailable: Bool = true
    ) -> HomebrewService {
        HomebrewService(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            runner: runner,
            networkAvailabilityChecker: StubNetworkAvailabilityChecker(
                isAvailable: networkIsAvailable
            ),
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

private struct StubNetworkAvailabilityChecker: NetworkAvailabilityChecking {
    let isAvailable: Bool

    func isNetworkAvailable() async -> Bool {
        isAvailable
    }
}

private actor StubCommandRunner: CommandRunning {
    enum StubError: Error {
        case missingResult
    }

    enum Response: Sendable {
        case result(CommandResult)
        case timeout(CommandTimeoutError)
    }

    private var responses: [Response]
    private var requests: [CommandRequest] = []

    init(results: [CommandResult]) {
        responses = results.map(Response.result)
    }

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(
        _ request: CommandRequest,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        requests.append(request)
        guard !responses.isEmpty else { throw StubError.missingResult }
        switch responses.removeFirst() {
        case let .result(result):
            onOutput?(result.combinedOutput)
            return result
        case let .timeout(error):
            throw error
        }
    }

    func recordedRequests() -> [CommandRequest] {
        requests
    }
}
