import Foundation

protocol HomebrewServicing: Sendable {
    func checkOutdated(
        greedy: Bool,
        refreshMetadata: Bool
    ) async throws -> [HomebrewPackage]

    func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        administratorPassword: String?,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult

    func cleanup(deep: Bool) async throws -> CleanupResult
}

extension HomebrewService: HomebrewServicing {}
