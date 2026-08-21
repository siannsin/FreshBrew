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

enum UpdateVerification: Codable, Hashable, Sendable {
    case completed
    case unavailable(HomebrewCommandFailure)

    var failure: HomebrewCommandFailure? {
        guard case let .unavailable(failure) = self else { return nil }
        return failure
    }
}

struct UpdateResult: Codable, Hashable, Sendable {
    let completedPackages: [UpdatedPackage]
    let remainingPackages: [HomebrewPackage]
    let failures: [HomebrewCommandFailure]
    let timestamp: Date
    let verification: UpdateVerification

    init(
        completedPackages: [UpdatedPackage],
        remainingPackages: [HomebrewPackage],
        failures: [HomebrewCommandFailure],
        timestamp: Date,
        verification: UpdateVerification = .completed
    ) {
        self.completedPackages = completedPackages
        self.remainingPackages = remainingPackages
        self.failures = failures
        self.timestamp = timestamp
        self.verification = verification
    }

    var completedCount: Int {
        completedPackages.count
    }

    var hasFailures: Bool {
        !failures.isEmpty || verification.failure != nil
    }
}
