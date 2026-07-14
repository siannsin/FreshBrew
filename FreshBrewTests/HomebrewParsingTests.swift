import XCTest
@testable import FreshBrew

final class HomebrewParsingTests: XCTestCase {
    func testOutdatedParserRecognizesFormulaeAndCasks() {
        let output = """
        ripgrep (14.1.0) < 14.1.1
        visual-studio-code (1.101.0) != 1.102.2
        ignored summary text
        """

        XCTAssertEqual(HomebrewService.parseOutdatedOutput(output), [
            HomebrewPackage(
                name: "ripgrep",
                installedVersion: "14.1.0",
                availableVersion: "14.1.1",
                kind: .formula
            ),
            HomebrewPackage(
                name: "visual-studio-code",
                installedVersion: "1.101.0",
                availableVersion: "1.102.2",
                kind: .cask
            )
        ])
    }

    func testOutdatedParserDeduplicatesPackageIdentity() {
        let output = """
        ripgrep (14.1.0) < 14.1.1
        ripgrep (14.1.0) < 14.1.1
        """

        XCTAssertEqual(HomebrewService.parseOutdatedOutput(output).count, 1)
    }

    func testGreedyArgumentsAreAddedOnlyWhenEnabled() {
        XCTAssertEqual(
            HomebrewService.outdatedArguments(greedy: false),
            ["outdated", "--verbose"]
        )
        XCTAssertEqual(
            HomebrewService.outdatedArguments(greedy: true),
            ["outdated", "--verbose", "--greedy"]
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

    private func package(named name: String, kind: HomebrewPackageKind) -> HomebrewPackage {
        HomebrewPackage(
            name: name,
            installedVersion: "1.0",
            availableVersion: "2.0",
            kind: kind
        )
    }
}
