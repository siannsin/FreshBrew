import Foundation

struct HomebrewCommandFailure: Codable, Hashable, Sendable {
    let operation: String
    let exitCode: Int32
    let output: String
}

struct UpdateResult: Codable, Hashable, Sendable {
    let completedPackages: [UpdatedPackage]
    let remainingPackages: [HomebrewPackage]
    let failures: [HomebrewCommandFailure]
    let timestamp: Date

    var completedCount: Int {
        completedPackages.count
    }

    var hasFailures: Bool {
        !failures.isEmpty
    }
}
