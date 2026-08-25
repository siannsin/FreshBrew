import Foundation
import XCTest
@testable import FreshBrew

private typealias OutdatedFixturePackage = (
    name: String,
    installedVersions: [String],
    currentVersion: String
)

private struct OutdatedFixture: Encodable {
    struct Package: Encodable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String

        private enum CodingKeys: String, CodingKey {
            case name
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
        }
    }

    let formulae: [Package]
    let casks: [Package]
}

private func outdatedJSON(
    formulae: [OutdatedFixturePackage] = [],
    casks: [OutdatedFixturePackage] = []
) -> String {
    let fixture = OutdatedFixture(
        formulae: formulae.map {
            OutdatedFixture.Package(
                name: $0.name,
                installedVersions: $0.installedVersions,
                currentVersion: $0.currentVersion
            )
        },
        casks: casks.map {
            OutdatedFixture.Package(
                name: $0.name,
                installedVersions: $0.installedVersions,
                currentVersion: $0.currentVersion
            )
        }
    )
    let data = try! JSONEncoder().encode(fixture)
    return String(decoding: data, as: UTF8.self)
}

private let emptyOutdatedJSON = outdatedJSON()

final class HomebrewServiceTests: XCTestCase {
    func testCurrentHomebrewHostArchitectureMatchesCompiledSlice() {
#if arch(arm64)
        XCTAssertEqual(HomebrewHostArchitecture.current, .appleSilicon)
#elseif arch(x86_64)
        XCTAssertEqual(HomebrewHostArchitecture.current, .intel)
#endif
    }

    func testHomebrewExecutableCandidatesPreferTheNativeArchitecture() {
        XCTAssertEqual(
            HomebrewExecutableLocator.candidateURLs(for: .appleSilicon).map(\.path),
            ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        )
        XCTAssertEqual(
            HomebrewExecutableLocator.candidateURLs(for: .intel).map(\.path),
            ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]
        )
    }

    func testHomebrewExecutableLocatorFallsBackToTheAvailableStandardPath() {
        let resolvedURL = HomebrewExecutableLocator.executableURL(
            for: .appleSilicon,
            isExecutable: { $0.path == "/usr/local/bin/brew" }
        )

        XCTAssertEqual(resolvedURL.path, "/usr/local/bin/brew")
    }

    func testServiceUsesDiscoveredHomebrewExecutable() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
        ])
        let service = HomebrewService(
            runner: runner,
            networkAvailabilityChecker: StubNetworkAvailabilityChecker(
                isAvailable: true
            ),
            executableIsAvailable: { $0.path == "/usr/local/bin/brew" }
        )

        _ = try await service.checkOutdated(
            greedy: false,
            refreshMetadata: false
        )

        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.first?.executableURL.path, "/usr/local/bin/brew")
    }

    func testPackageHomepageUsesKindSpecificHomebrewInfoMetadata() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: """
                {"formulae":[{"homepage":"https://github.com/BurntSushi/ripgrep"}],"casks":[]}
                """,
                standardError: ""
            ),
            CommandResult(
                exitCode: 0,
                standardOutput: """
                {"formulae":[],"casks":[{"homepage":"https://chatgpt.com/"}]}
                """,
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let formulaURL = try await service.packageHomepageURL(
            packageName: "ripgrep",
            kind: .formula
        )
        let caskURL = try await service.packageHomepageURL(
            packageName: "chatgpt",
            kind: .cask
        )

        XCTAssertEqual(formulaURL.absoluteString, "https://github.com/BurntSushi/ripgrep")
        XCTAssertEqual(caskURL.absoluteString, "https://chatgpt.com/")
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["info", "--json=v2", "--formula", "ripgrep"],
            ["info", "--json=v2", "--cask", "chatgpt"]
        ])
        XCTAssertEqual(
            requests.map(\.timeoutPolicy),
            [HomebrewService.homepageTimeoutPolicy, HomebrewService.homepageTimeoutPolicy]
        )
        XCTAssertEqual(
            requests.map { $0.environment["HOMEBREW_NO_AUTO_UPDATE"] },
            ["1", "1"]
        )
    }

    func testBulkPackageHomepagesUseOneCommandPerKind() async throws {
        let output = """
        {"formulae":[{"name":"ripgrep","homepage":"https://github.com/BurntSushi/ripgrep"}],"casks":[{"token":"chatgpt","homepage":"https://chatgpt.com/"}]}
        """
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: output, standardError: ""),
            CommandResult(exitCode: 0, standardOutput: output, standardError: "")
        ])
        let service = makeService(runner: runner)
        let packages = [
            package(named: "ripgrep", kind: .formula),
            package(named: "chatgpt", kind: .cask)
        ]

        let urls = await service.packageHomepageURLs(for: packages)

        XCTAssertEqual(
            urls["formula:ripgrep"]?.absoluteString,
            "https://github.com/BurntSushi/ripgrep"
        )
        XCTAssertEqual(urls["cask:chatgpt"]?.absoluteString, "https://chatgpt.com/")
        let requests = await runner.recordedRequests()
        XCTAssertEqual(Set(requests.map(\.arguments)), Set([
            ["info", "--json=v2", "--formula", "ripgrep"],
            ["info", "--json=v2", "--cask", "chatgpt"]
        ]))
        XCTAssertTrue(requests.allSatisfy {
            $0.timeoutPolicy == HomebrewService.homepageTimeoutPolicy
                && $0.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1"
        })
    }

    func testPackageHomepageRejectsMissingAndNonWebURLs() {
        XCTAssertThrowsError(try HomebrewService.parsePackageHomepageURL(
            from: #"{"formulae":[{"homepage":null}],"casks":[]}"#,
            kind: .formula
        )) { error in
            XCTAssertEqual(error as? PackageHomepageError, .unavailable)
        }

        XCTAssertThrowsError(try HomebrewService.parsePackageHomepageURL(
            from: #"{"formulae":[],"casks":[{"homepage":"file:///tmp/example"}]}"#,
            kind: .cask
        )) { error in
            XCTAssertEqual(
                error as? PackageHomepageError,
                .invalidURL("file:///tmp/example")
            )
        }
    }

    func testCheckOutdatedRefreshesThenUsesGreedySetting() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(
                exitCode: 0,
                standardOutput: outdatedJSON(
                    casks: [("firefox", ["1.0"], "2.0")]
                ),
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let packages = try await service.checkOutdated(greedy: true)

        XCTAssertEqual(packages.map(\.name), ["firefox"])
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["update"],
            ["outdated", "--json=v2", "--greedy"]
        ])
        XCTAssertEqual(requests.map(\.timeoutPolicy), [
            HomebrewService.metadataTimeoutPolicy,
            HomebrewService.outdatedTimeoutPolicy
        ])
        XCTAssertEqual(
            requests.last?.environment["HOMEBREW_NO_AUTO_UPDATE"],
            "1"
        )
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

    func testCheckOutdatedTreatsMalformedJSONAsCommandFailure() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "unexpected output",
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        do {
            _ = try await service.checkOutdated(
                greedy: false,
                refreshMetadata: false
            )
            XCTFail("Expected malformed JSON to fail the check")
        } catch let HomebrewError.commandFailed(failure) {
            XCTAssertEqual(failure.operation, "decode outdated packages")
            XCTAssertTrue(failure.output.contains("unexpected output"))
            XCTAssertTrue(failure.output.contains("could not decode"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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
                standardOutput: outdatedJSON(
                    formulae: [("second", ["1.0"], "2.0")]
                ),
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
            ["outdated", "--json=v2"]
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
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
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
                standardOutput: outdatedJSON(
                    casks: [("large-cask", ["1.0"], "2.0")]
                ),
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
            ["outdated", "--json=v2", "--greedy"]
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
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(packages: [package], greedy: true)

        XCTAssertEqual(result.completedPackages.map(\.name), ["duckduckgo"])
        XCTAssertFalse(result.hasFailures)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["upgrade", "--cask", "--greedy", "duckduckgo"],
            ["reinstall", "--cask", "--force", "duckduckgo"],
            ["outdated", "--json=v2", "--greedy"]
        ])
    }

    func testUpdatePreservesSuccessfulBatchWhenVerificationTimesOut() async throws {
        let package = package(named: "spotify", kind: .cask)
        let runner = StubCommandRunner(responses: [
            .result(CommandResult(
                exitCode: 0,
                standardOutput: "spotify updated",
                standardError: ""
            )),
            .timeout(CommandTimeoutError(
                reason: .absolute,
                limit: 60,
                output: "verification stalled"
            ))
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(packages: [package], greedy: true)

        XCTAssertEqual(result.completedPackages.map(\.name), ["spotify"])
        XCTAssertTrue(result.remainingPackages.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        guard case let .unavailable(failure) = result.verification else {
            return XCTFail("Expected verification to be unavailable")
        }
        XCTAssertEqual(failure.operation, "verify updates")
        XCTAssertEqual(failure.kind, .timeout)
        XCTAssertTrue(failure.output.contains("verification stalled"))
    }

    func testUpdatePreservesOnlySuccessfulBatchWhenVerificationIsUnavailable() async throws {
        let formula = package(named: "ripgrep", kind: .formula)
        let cask = package(named: "stats", kind: .cask)
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "formula updated", standardError: ""),
            CommandResult(exitCode: 1, standardOutput: "", standardError: "permission denied"),
            CommandResult(exitCode: 1, standardOutput: "", standardError: "outdated failed")
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(
            packages: [formula, cask],
            greedy: false
        )

        XCTAssertEqual(result.completedPackages.map(\.name), ["ripgrep"])
        XCTAssertEqual(result.remainingPackages.map(\.name), ["stats"])
        XCTAssertEqual(result.failures.map(\.operation), ["upgrade casks"])
        guard case let .unavailable(failure) = result.verification else {
            return XCTFail("Expected verification to be unavailable")
        }
        XCTAssertEqual(failure.operation, "verify updates")
        XCTAssertTrue(failure.output.contains("outdated failed"))
    }

    func testUpdateTreatsMalformedVerificationOutputAsUnavailable() async throws {
        let package = package(named: "ripgrep", kind: .formula)
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(
                exitCode: 0,
                standardOutput: "unexpected verification output",
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let result = try await service.update(packages: [package], greedy: false)

        XCTAssertEqual(result.completedPackages.map(\.name), ["ripgrep"])
        guard case let .unavailable(failure) = result.verification else {
            return XCTFail("Expected malformed verification to be unavailable")
        }
        XCTAssertEqual(failure.operation, "verify updates")
        XCTAssertTrue(failure.output.contains("unexpected verification output"))
    }

    func testUpdateUsesBundledAskpassWithoutTransportingPassword() async throws {
        let package = package(named: "firefox", kind: .cask)
        let helperURL = URL(fileURLWithPath: "/Applications/FreshBrew.app/Contents/Helpers/FreshBrewAskpass")
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
        ])
        let service = makeService(
            runner: runner,
            authorizationContext: AdminAuthorizationContext(
                askpassExecutableURL: helperURL
            )
        )

        _ = try await service.update(packages: [package], greedy: false)

        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.first?.environment["SUDO_ASKPASS"], helperURL.path)
        XCTAssertNil(requests.first?.environment["SUDO_ASKPASS_REQUIRE"])
        XCTAssertFalse(requests.first?.arguments.contains { $0.contains("password") } ?? true)
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

    func testFreshBrewSelfUpdateUsesNoQuitAndGreedyOnlyForExactCask() async throws {
        let freshBrew = package(named: "freshbrew", kind: .cask)
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        _ = try await service.updateFreshBrew(
            package: freshBrew,
            greedy: true
        )

        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.map(\.arguments), [
            ["upgrade", "--cask", "--greedy", "--no-quit", "freshbrew"],
            ["outdated", "--json=v2", "--greedy"]
        ])
    }

    func testNormalUpdateNeverAddsNoQuitForAnotherPackage() async throws {
        let cask = package(named: "spotify", kind: .cask)
        let runner = StubCommandRunner(results: [
            CommandResult(exitCode: 0, standardOutput: "updated", standardError: ""),
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        _ = try await service.update(packages: [cask], greedy: true)

        let requests = await runner.recordedRequests()
        XCTAssertEqual(
            requests.first?.arguments,
            ["upgrade", "--cask", "--greedy", "spotify"]
        )
        XCTAssertFalse(requests.first?.arguments.contains("--no-quit") == true)
    }

    private func makeService(
        runner: StubCommandRunner,
        networkIsAvailable: Bool = true,
        authorizationContext: AdminAuthorizationContext? = nil
    ) -> HomebrewService {
        HomebrewService(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            runner: runner,
            networkAvailabilityChecker: StubNetworkAvailabilityChecker(
                isAvailable: networkIsAvailable
            ),
            authorizationContext: authorizationContext,
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
