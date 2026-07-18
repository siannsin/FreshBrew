import Foundation

struct HomebrewCommandFailure: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case command
        case timeout
    }

    let operation: String
    let exitCode: Int32
    let output: String
    let kind: Kind

    init(
        operation: String,
        exitCode: Int32,
        output: String,
        kind: Kind = .command
    ) {
        self.operation = operation
        self.exitCode = exitCode
        self.output = output
        self.kind = kind
    }
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
