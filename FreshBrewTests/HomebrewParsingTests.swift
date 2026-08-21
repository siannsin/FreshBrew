import XCTest
@testable import FreshBrew

final class HomebrewParsingTests: XCTestCase {
    func testHomebrewNotFoundMessageSupportsBothArchitectures() {
        let error = HomebrewError.executableNotFound(
            URL(fileURLWithPath: "/usr/local/bin/brew")
        )

        XCTAssertEqual(
            error.errorDescription,
            "Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew."
        )
    }

    func testOutdatedJSONParserReturnsEmptyPackageList() throws {
        let output = #"{"formulae":[],"casks":[]}"#

        XCTAssertEqual(try HomebrewService.parseOutdatedJSON(output), [])
    }

    func testOutdatedJSONParserPreservesFormulaAndCaskOrdering() throws {
        let output = """
        {
          "formulae": [
            {
              "name": "ripgrep",
              "installed_versions": ["14.1.0", "14.1.0_1"],
              "current_version": "14.1.1",
              "pinned": false,
              "future_field": "ignored"
            },
            {
              "name": "wget",
              "installed_versions": ["1.24.5"],
              "current_version": "1.25.0"
            }
          ],
          "casks": [
            {
              "name": "visual-studio-code",
              "installed_versions": ["1.101.0"],
              "current_version": "1.102.2"
            },
            {
              "name": "chatgpt",
              "installed_versions": ["1.22209.0,77c938bac"],
              "current_version": "1.22209.3,babe11577"
            }
          ],
          "future_top_level_field": true
        }
        """

        XCTAssertEqual(try HomebrewService.parseOutdatedJSON(output), [
            HomebrewPackage(
                name: "ripgrep",
                installedVersion: "14.1.0, 14.1.0_1",
                availableVersion: "14.1.1",
                kind: .formula
            ),
            HomebrewPackage(
                name: "wget",
                installedVersion: "1.24.5",
                availableVersion: "1.25.0",
                kind: .formula
            ),
            HomebrewPackage(
                name: "visual-studio-code",
                installedVersion: "1.101.0",
                availableVersion: "1.102.2",
                kind: .cask
            ),
            HomebrewPackage(
                name: "chatgpt",
                installedVersion: "1.22209.0,77c938bac",
                availableVersion: "1.22209.3,babe11577",
                kind: .cask
            )
        ])
    }

    func testOutdatedJSONParserRejectsMissingRequiredFieldsAndMalformedJSON() {
        let missingField = #"{"formulae":[{"name":"ripgrep","installed_versions":["14.1.0"]}],"casks":[]}"#
        let emptyInstalledVersions = #"{"formulae":[],"casks":[{"name":"chatgpt","installed_versions":[],"current_version":"2.0"}]}"#

        XCTAssertThrowsError(try HomebrewService.parseOutdatedJSON(missingField))
        XCTAssertThrowsError(try HomebrewService.parseOutdatedJSON(emptyInstalledVersions))
        XCTAssertThrowsError(try HomebrewService.parseOutdatedJSON("not json"))
    }

    func testGreedyArgumentsAreAddedOnlyWhenEnabled() {
        XCTAssertEqual(
            HomebrewService.outdatedArguments(greedy: false),
            ["outdated", "--json=v2"]
        )
        XCTAssertEqual(
            HomebrewService.outdatedArguments(greedy: true),
            ["outdated", "--json=v2", "--greedy"]
        )
    }

    func testUpgradeArgumentsDisambiguateFormulaeAndCasks() {
        let formula = package(named: "ripgrep", kind: .formula)
        let cask = package(named: "firefox", kind: .cask)

        XCTAssertEqual(
            HomebrewService.upgradeArguments(for: [formula], greedy: true),
            ["upgrade", "--formula", "ripgrep"]
        )
        XCTAssertEqual(
            HomebrewService.upgradeArguments(for: [cask], greedy: true),
            ["upgrade", "--cask", "--greedy", "firefox"]
        )
    }

    func testForcedReinstallParserMatchesExactHomebrewWarningAndDeduplicates() {
        let output = """
        Warning: The cask 'duckduckgo' cannot be upgraded as-is. To fix this, run:
        brew reinstall --cask --force duckduckgo
        Warning: The cask 'duckduckgo' cannot be upgraded as-is. To fix this, run:
        Warning: A cask cannot be upgraded as-is.
        """

        XCTAssertEqual(
            HomebrewService.casksNeedingForcedReinstall(from: output),
            ["duckduckgo"]
        )
    }

    func testExistingApplicationConflictExtractsPath() {
        let output = "Error: stats: It seems there is already an App at '/Applications/Stats.app'."

        XCTAssertEqual(
            HomebrewError.existingApplicationPath(in: output),
            "/Applications/Stats.app"
        )
        XCTAssertEqual(
            HomebrewError.classified(operation: "upgrade", exitCode: 1, output: output),
            .existingApplicationConflict(path: "/Applications/Stats.app", output: output)
        )
    }

    func testPermissionFailureClassification() {
        let output = "sudo: a password is required"
        XCTAssertEqual(
            HomebrewError.classified(operation: "upgrade", exitCode: 1, output: output),
            .permissionRequired(output)
        )
    }

    func testNetworkFailureDetectionMatchesCommonDNSAndConnectionErrors() {
        let outputs = [
            "fatal: unable to access a repository: Could not resolve host: github.com",
            "ssh: Could not resolve hostname github.com: nodename nor servname provided",
            "curl: (7) Failed to connect to formulae.brew.sh port 443",
            "connect: Network is unreachable",
            "fatal: unable to access a repository: No route to host"
        ]

        for output in outputs {
            let error = HomebrewError.classified(
                operation: "update metadata",
                exitCode: 1,
                output: output
            )
            XCTAssertTrue(error.indicatesNetworkFailure, output)
            XCTAssertEqual(
                error.errorDescription,
                "Network unavailable. Check your connection and try again."
            )
        }
    }

    func testNetworkFailureDetectionIgnoresUnrelatedHomebrewErrors() {
        let error = HomebrewError.classified(
            operation: "update metadata",
            exitCode: 1,
            output: "Error: Fetching a tap failed because the repository does not exist"
        )

        XCTAssertFalse(error.indicatesNetworkFailure)
        XCTAssertEqual(
            error.errorDescription,
            "Homebrew could not complete the operation."
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
