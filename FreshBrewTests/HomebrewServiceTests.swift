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

    func testInstalledPackagesUsesOneBoundedLocalMetadataCommand() async throws {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: """
                {
                  "formulae": [{
                    "name": "ripgrep",
                    "homepage": "https://github.com/BurntSushi/ripgrep",
                    "linked_keg": "14.1.1",
                    "installed": [{"version": "13.0.0"}, {"version": "14.1.1"}]
                  }],
                  "casks": [{
                    "token": "android-studio",
                    "homepage": "https://developer.android.com/studio",
                    "installed": "2026.1.3.8,quail3-patch1"
                  }]
                }
                """,
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        let packages = try await service.installedPackages()

        XCTAssertEqual(packages.map(\.id), ["formula:ripgrep", "cask:android-studio"])
        XCTAssertEqual(packages.map(\.installedVersion), [
            "14.1.1",
            "2026.1.3.8,quail3-patch1"
        ])
        XCTAssertEqual(
            packages[0].homepageURL?.absoluteString,
            "https://github.com/BurntSushi/ripgrep"
        )
        XCTAssertEqual(
            HomebrewVersionDisplay.compact(
                packages[1].installedVersion,
                kind: packages[1].kind
            ),
            "2026.1.3.8"
        )

        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].arguments, ["info", "--json=v2", "--installed"])
        XCTAssertEqual(requests[0].environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
        XCTAssertEqual(requests[0].timeoutPolicy, HomebrewService.outdatedTimeoutPolicy)
    }

    func testInstalledFormulaFallsBackToMostRecentInstallationWhenUnlinked() throws {
        let packages = try HomebrewService.parseInstalledPackagesJSON("""
        {
          "formulae": [{
            "name": "openssl@3",
            "homepage": "file:///tmp/not-a-homepage",
            "linked_keg": null,
            "installed": [{"version": "3.5.1"}, {"version": "3.5.2"}]
          }],
          "casks": []
        }
        """)

        XCTAssertEqual(packages, [
            InstalledPackage(
                name: "openssl@3",
                installedVersion: "3.5.2",
                kind: .formula
            )
        ])
    }

    func testInstalledPackageDecoderAcceptsEmptyInventory() throws {
        XCTAssertEqual(
            try HomebrewService.parseInstalledPackagesJSON(
                #"{"formulae":[],"casks":[]}"#
            ),
            []
        )
    }

    func testInstalledPackageDecoderRejectsMissingVersion() {
        XCTAssertThrowsError(try HomebrewService.parseInstalledPackagesJSON("""
        {
          "formulae": [],
          "casks": [{
            "token": "chatgpt",
            "homepage": "https://chatgpt.com/",
            "installed": null
          }]
        }
        """)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Homebrew returned no installed version for cask chatgpt."
            )
        }
    }

    func testInstalledPackagesTreatsMalformedJSONAsCommandFailure() async {
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "unexpected output",
                standardError: ""
            )
        ])
        let service = makeService(runner: runner)

        do {
            _ = try await service.installedPackages()
            XCTFail("Expected malformed installed-package JSON to fail")
        } catch let HomebrewError.commandFailed(failure) {
            XCTAssertEqual(failure.operation, "decode installed packages")
            XCTAssertTrue(failure.output.contains("unexpected output"))
            XCTAssertTrue(failure.output.contains("could not decode"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInstalledPackagesPropagatesCommandFailureAndTimeout() async {
        let commandFailureRunner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "metadata unavailable"
            )
        ])
        let commandFailureService = makeService(runner: commandFailureRunner)

        do {
            _ = try await commandFailureService.installedPackages()
            XCTFail("Expected installed-package command failure")
        } catch let HomebrewError.commandFailed(failure) {
            XCTAssertEqual(failure.operation, "read installed packages")
            XCTAssertEqual(failure.output, "metadata unavailable")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let timeoutRunner = StubCommandRunner(responses: [
            .timeout(CommandTimeoutError(
                reason: .absolute,
                limit: 30,
                output: "metadata stalled"
            ))
        ])
        let timeoutService = makeService(runner: timeoutRunner)

        do {
            _ = try await timeoutService.installedPackages()
            XCTFail("Expected installed-package timeout")
        } catch let HomebrewError.timedOut(operation, seconds, output) {
            XCTAssertEqual(operation, "read installed packages")
            XCTAssertEqual(seconds, 30)
            XCTAssertEqual(output, "metadata stalled")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    func testUpdateSharesValidatedActivePackageWithAskpassAndRemovesContext() async throws {
        let packages = [
            package(named: "ripgrep", kind: .formula),
            package(named: "wget", kind: .formula)
        ]
        let helperURL = URL(fileURLWithPath: "/Applications/FreshBrew.app/Contents/Helpers/FreshBrewAskpass")
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "==> Upgrading wget",
                standardError: ""
            ),
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

        _ = try await service.update(packages: packages, greedy: false)

        let requests = await runner.recordedRequests()
        let observedPackages = await runner.observedAskpassPackageNames()
        let contextPath = try XCTUnwrap(
            requests.first?.environment[AskpassPackageContextSession.environmentKey]
        )
        XCTAssertEqual(observedPackages.first, "wget")
        XCTAssertFalse(FileManager.default.fileExists(atPath: contextPath))
    }

    func testUnknownProgressPackageLeavesAskpassContextGeneric() async throws {
        let packages = [
            package(named: "ripgrep", kind: .formula),
            package(named: "wget", kind: .formula)
        ]
        let runner = StubCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                standardOutput: "==> Upgrading unrelated-package",
                standardError: ""
            ),
            CommandResult(
                exitCode: 0,
                standardOutput: emptyOutdatedJSON,
                standardError: ""
            )
        ])
        let service = makeService(
            runner: runner,
            authorizationContext: AdminAuthorizationContext(
                askpassExecutableURL: URL(fileURLWithPath: "/tmp/FreshBrewAskpass")
            )
        )

        _ = try await service.update(packages: packages, greedy: false)

        let observedPackages = await runner.observedAskpassPackageNames()
        XCTAssertNil(observedPackages.first ?? nil)
    }

    func testUnexpectedUpdateExitRemovesAskpassContext() async throws {
        let helperURL = URL(fileURLWithPath: "/tmp/FreshBrewAskpass")
        let runner = StubCommandRunner(results: [])
        let service = makeService(
            runner: runner,
            authorizationContext: AdminAuthorizationContext(
                askpassExecutableURL: helperURL
            )
        )

        do {
            _ = try await service.update(
                packages: [package(named: "firefox", kind: .cask)],
                greedy: false
            )
            XCTFail("Expected the missing stub result to fail")
        } catch {
            let requests = await runner.recordedRequests()
            let contextPath = try XCTUnwrap(
                requests.first?.environment[AskpassPackageContextSession.environmentKey]
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: contextPath))
        }
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
    private var askpassPackageNames: [String?] = []

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
            askpassPackageNames.append(
                AskpassPackageContextSession.currentPackageName(
                    environment: request.environment
                )
            )
            return result
        case let .timeout(error):
            askpassPackageNames.append(
                AskpassPackageContextSession.currentPackageName(
                    environment: request.environment
                )
            )
            throw error
        }
    }

    func recordedRequests() -> [CommandRequest] {
        requests
    }

    func observedAskpassPackageNames() -> [String?] {
        askpassPackageNames
    }
}
