import Foundation

struct HomebrewCheckResult: Sendable {
    let packages: [HomebrewPackage]
    var refreshFailure: HomebrewCommandFailure? = nil
}

struct HomebrewCheckFailure: Error {
    let refreshFailure: HomebrewCommandFailure
    let listingError: any Error
}

protocol HomebrewServicing: Sendable {
    func installedPackages() async throws -> [InstalledPackage]

    func checkOutdated(
        greedy: Bool,
        refreshMetadata: Bool
    ) async throws -> HomebrewCheckResult

    func packageHomepageURLs(
        for packages: [HomebrewPackage]
    ) async -> [String: URL]

    func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult

    func updateFreshBrew(
        package: HomebrewPackage,
        greedy: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult

    func cleanup(deep: Bool) async throws -> CleanupResult
}

extension HomebrewService: HomebrewServicing {}
