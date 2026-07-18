import Foundation
import Network

protocol NetworkAvailabilityChecking: Sendable {
    func isNetworkAvailable() async -> Bool
}

struct SystemNetworkAvailabilityChecker: NetworkAvailabilityChecking {
    func isNetworkAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            NetworkPathProbe(continuation: continuation).start()
        }
    }
}

private final class NetworkPathProbe: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.siann.freshbrew.network-path")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func start() {
        monitor.pathUpdateHandler = { [self] path in
            finish(isAvailable: path.status == .satisfied)
        }
        monitor.start(queue: queue)

        // If the system cannot provide a path promptly, allow Homebrew to
        // proceed and let the command deadline remain authoritative.
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            finish(isAvailable: true)
        }
    }

    private func finish(isAvailable: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }

        monitor.pathUpdateHandler = nil
        monitor.cancel()
        continuation.resume(returning: isAvailable)
    }
}

actor HomebrewService {
    static let defaultExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    static let metadataTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 60)
    static let outdatedTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 30)
    static let packageTimeoutPolicy = CommandTimeoutPolicy(
        absoluteLimit: 30 * 60,
        inactivityLimit: 5 * 60
    )
    static let cleanupTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 5 * 60)

    private let executableURL: URL
    private let runner: any CommandRunning
    private let executableIsAvailable: @Sendable (URL) -> Bool
    private let networkAvailabilityChecker: any NetworkAvailabilityChecking

    init(
        executableURL: URL = HomebrewService.defaultExecutableURL,
        runner: any CommandRunning = SystemCommandRunner(),
        networkAvailabilityChecker: any NetworkAvailabilityChecking = SystemNetworkAvailabilityChecker(),
        executableIsAvailable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.networkAvailabilityChecker = networkAvailabilityChecker
        self.executableIsAvailable = executableIsAvailable
    }

    func checkOutdated(
        greedy: Bool,
        refreshMetadata: Bool = true
    ) async throws -> [HomebrewPackage] {
        try ensureExecutableIsAvailable()

        if refreshMetadata {
            try await ensureNetworkIsAvailable()
            let refreshResult = try await run(
                arguments: ["update"],
                operation: "update metadata",
                timeoutPolicy: Self.metadataTimeoutPolicy
            )
            try requireSuccess(refreshResult, operation: "update metadata")
        }

        let outdatedResult = try await run(
            arguments: Self.outdatedArguments(greedy: greedy),
            operation: "check outdated packages",
            timeoutPolicy: Self.outdatedTimeoutPolicy
        )
        try requireSuccess(outdatedResult, operation: "check outdated packages")
        return Self.parseOutdatedOutput(outdatedResult.standardOutput)
    }

    func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        administratorPassword: String? = nil,
        onProgress: (@Sendable (UpdateProgress) -> Void)? = nil
    ) async throws -> UpdateResult {
        try ensureExecutableIsAvailable()

        let candidates = Self.deduplicated(packages)
        guard !candidates.isEmpty else {
            return UpdateResult(
                completedPackages: [],
                remainingPackages: [],
                failures: [],
                timestamp: Date()
            )
        }
        try await ensureNetworkIsAvailable()

        let authorizationContext = try administratorPassword.map {
            try AdminAuthorizationContext.create(password: $0)
        }
        defer { authorizationContext?.removeFiles() }

        let environment = authorizationContext?.environment ?? [:]
        var commandFailures: [HomebrewCommandFailure] = []
        var combinedUpgradeOutput = ""
        var updateTimedOut = false

        onProgress?(UpdateProgress(
            stage: .preparing,
            packageName: nil,
            message: "Preparing \(candidates.count) package update\(candidates.count == 1 ? "" : "s")"
        ))

        for kind in HomebrewPackageKind.allCases {
            let group = candidates.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }

            let operation = "upgrade \(kind.rawValue)s"
            do {
                let result = try await run(
                    arguments: Self.upgradeArguments(for: group, greedy: greedy),
                    environment: environment,
                    operation: operation,
                    timeoutPolicy: Self.packageTimeoutPolicy,
                    onOutput: progressRelay(stage: .upgrading, onProgress: onProgress)
                )
                combinedUpgradeOutput += "\n" + result.combinedOutput

                if result.exitCode != 0 {
                    commandFailures.append(HomebrewCommandFailure(
                        operation: operation,
                        exitCode: result.exitCode,
                        output: result.combinedOutput
                    ))
                }
            } catch let error as HomebrewError {
                guard let failure = Self.timeoutFailure(from: error) else { throw error }
                commandFailures.append(failure)
                updateTimedOut = true
                break
            }
        }

        let refusedNames = Set(Self.casksNeedingForcedReinstall(from: combinedUpgradeOutput))
        let refusedCasks = updateTimedOut ? [] : candidates.filter {
            $0.kind == .cask && refusedNames.contains($0.name)
        }

        for package in refusedCasks {
            onProgress?(UpdateProgress(
                stage: .reinstalling,
                packageName: package.name,
                message: "Reinstalling \(package.name)"
            ))

            let operation = "force reinstall \(package.name)"
            do {
                let reinstallResult = try await run(
                    arguments: ["reinstall", "--cask", "--force", package.name],
                    environment: environment,
                    operation: operation,
                    timeoutPolicy: Self.packageTimeoutPolicy,
                    onOutput: progressRelay(stage: .reinstalling, onProgress: onProgress)
                )
                if reinstallResult.exitCode != 0 {
                    commandFailures.append(HomebrewCommandFailure(
                        operation: operation,
                        exitCode: reinstallResult.exitCode,
                        output: reinstallResult.combinedOutput
                    ))
                }
            } catch let error as HomebrewError {
                guard let failure = Self.timeoutFailure(from: error) else { throw error }
                commandFailures.append(failure)
                break
            }
        }

        onProgress?(UpdateProgress(
            stage: .verifying,
            packageName: nil,
            message: "Verifying Homebrew updates"
        ))

        let remainingPackages = try await checkOutdated(
            greedy: greedy,
            refreshMetadata: false
        )
        let remainingIDs = Set(remainingPackages.map(\.id))
        let completedPackages = candidates.compactMap { package -> UpdatedPackage? in
            guard !remainingIDs.contains(package.id) else { return nil }
            return UpdatedPackage(
                name: package.name,
                previousVersion: package.installedVersion,
                installedVersion: package.availableVersion,
                kind: package.kind
            )
        }

        let unfinishedCandidateIDs = Set(candidates.map(\.id)).intersection(remainingIDs)
        if !unfinishedCandidateIDs.isEmpty, commandFailures.isEmpty {
            commandFailures.append(HomebrewCommandFailure(
                operation: "verify updates",
                exitCode: 0,
                output: "Homebrew still reports \(unfinishedCandidateIDs.count) selected package(s) as outdated."
            ))
        }

        return UpdateResult(
            completedPackages: completedPackages,
            remainingPackages: remainingPackages,
            failures: commandFailures,
            timestamp: Date()
        )
    }

    func cleanup(deep: Bool) async throws -> CleanupResult {
        try ensureExecutableIsAvailable()
        let arguments = deep ? ["cleanup", "--prune=all"] : ["cleanup"]
        let operation = deep ? "deep cleanup" : "cleanup"
        let result = try await run(
            arguments: arguments,
            operation: operation,
            timeoutPolicy: Self.cleanupTimeoutPolicy
        )
        try requireSuccess(result, operation: operation)
        return CleanupResult(
            isDeepCleanup: deep,
            output: result.combinedOutput,
            completedAt: Date()
        )
    }

    func recoverConflictingCask(
        _ package: HomebrewPackage,
        applicationURL: URL,
        greedy: Bool,
        administratorPassword: String? = nil,
        recoveryStore: CaskRecoveryStore = CaskRecoveryStore(),
        onProgress: (@Sendable (UpdateProgress) -> Void)? = nil
    ) async throws -> UpdateResult {
        guard package.kind == .cask else {
            throw HomebrewError.invalidRecoveryTarget(applicationURL)
        }

        try ensureExecutableIsAvailable()
        try await ensureNetworkIsAvailable()
        _ = try recoveryStore.removeBackups(
            olderThan: Date().addingTimeInterval(-7 * 24 * 60 * 60)
        )
        let backup = try recoveryStore.stageApplication(at: applicationURL)
        var shouldRestoreBackup = true

        do {
            let authorizationContext = try administratorPassword.map {
                try AdminAuthorizationContext.create(password: $0)
            }
            defer { authorizationContext?.removeFiles() }

            onProgress?(UpdateProgress(
                stage: .reinstalling,
                packageName: package.name,
                message: "Recovering \(package.name)"
            ))
            let result = try await run(
                arguments: ["reinstall", "--cask", "--force", package.name],
                environment: authorizationContext?.environment ?? [:],
                operation: "recover cask \(package.name)",
                timeoutPolicy: Self.packageTimeoutPolicy,
                onOutput: progressRelay(stage: .reinstalling, onProgress: onProgress)
            )
            try requireSuccess(result, operation: "recover cask \(package.name)")

            try recoveryStore.discard(backup)
            shouldRestoreBackup = false

            let remainingPackages = try await checkOutdated(
                greedy: greedy,
                refreshMetadata: false
            )
            let isStillOutdated = remainingPackages.contains { $0.id == package.id }
            let completedPackages = isStillOutdated ? [] : [UpdatedPackage(
                name: package.name,
                previousVersion: package.installedVersion,
                installedVersion: package.availableVersion,
                kind: package.kind
            )]
            let failures = isStillOutdated ? [HomebrewCommandFailure(
                operation: "verify recovered cask",
                exitCode: 0,
                output: "Homebrew still reports \(package.name) as outdated after recovery."
            )] : []

            return UpdateResult(
                completedPackages: completedPackages,
                remainingPackages: remainingPackages,
                failures: failures,
                timestamp: Date()
            )
        } catch {
            if shouldRestoreBackup {
                try? recoveryStore.restore(backup)
            }
            throw error
        }
    }

    nonisolated static func outdatedArguments(greedy: Bool) -> [String] {
        var arguments = ["outdated", "--verbose"]
        if greedy {
            arguments.append("--greedy")
        }
        return arguments
    }

    nonisolated static func upgradeArguments(
        for packages: [HomebrewPackage],
        greedy: Bool
    ) -> [String] {
        guard let kind = packages.first?.kind else { return [] }
        var arguments = ["upgrade", kind == .cask ? "--cask" : "--formula"]
        if greedy, kind == .cask {
            arguments.append("--greedy")
        }
        arguments.append(contentsOf: packages.map(\.name))
        return arguments
    }

    nonisolated static func parseOutdatedOutput(_ output: String) -> [HomebrewPackage] {
        let pattern = #"^(.+?)\s+\((.+)\)\s*(<|!=)\s*(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        var packages: [HomebrewPackage] = []
        var seenIDs = Set<String>()

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  match.numberOfRanges == 5,
                  let nameRange = Range(match.range(at: 1), in: line),
                  let installedRange = Range(match.range(at: 2), in: line),
                  let separatorRange = Range(match.range(at: 3), in: line),
                  let availableRange = Range(match.range(at: 4), in: line) else {
                continue
            }

            let separator = String(line[separatorRange])
            let package = HomebrewPackage(
                name: String(line[nameRange]).trimmingCharacters(in: .whitespaces),
                installedVersion: String(line[installedRange]).trimmingCharacters(in: .whitespaces),
                availableVersion: String(line[availableRange]).trimmingCharacters(in: .whitespaces),
                kind: separator == "!=" ? .cask : .formula
            )

            if seenIDs.insert(package.id).inserted {
                packages.append(package)
            }
        }

        return packages
    }

    nonisolated static func casksNeedingForcedReinstall(from output: String) -> [String] {
        let pattern = #"The cask ['\"]([^'\"]+)['\"] cannot be upgraded as-is"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        var names: [String] = []
        var seen = Set<String>()

        for match in expression.matches(in: output, range: fullRange) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: output) else {
                continue
            }
            let name = String(output[nameRange])
            if seen.insert(name).inserted {
                names.append(name)
            }
        }

        return names
    }

    private func ensureExecutableIsAvailable() throws {
        guard executableIsAvailable(executableURL) else {
            throw HomebrewError.executableNotFound(executableURL)
        }
    }

    private func ensureNetworkIsAvailable() async throws {
        guard await networkAvailabilityChecker.isNetworkAvailable() else {
            throw HomebrewError.networkUnavailable
        }
    }

    private func run(
        arguments: [String],
        environment: [String: String] = [:],
        operation: String,
        timeoutPolicy: CommandTimeoutPolicy,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        do {
            return try await runner.run(
                CommandRequest(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    timeoutPolicy: timeoutPolicy
                ),
                onOutput: onOutput
            )
        } catch let error as CommandTimeoutError {
            throw HomebrewError.timedOut(
                operation: operation,
                seconds: error.limit,
                output: error.output
            )
        }
    }

    private nonisolated static func timeoutFailure(
        from error: HomebrewError
    ) -> HomebrewCommandFailure? {
        guard case let .timedOut(operation, seconds, output) = error else {
            return nil
        }
        let timeoutDescription = "FreshBrew stopped \(operation) after \(Int(seconds)) seconds."
        let diagnosticOutput = [output, timeoutDescription]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return HomebrewCommandFailure(
            operation: operation,
            exitCode: -1,
            output: diagnosticOutput,
            kind: .timeout
        )
    }

    private func requireSuccess(
        _ result: CommandResult,
        operation: String
    ) throws {
        guard result.exitCode == 0 else {
            throw HomebrewError.classified(
                operation: operation,
                exitCode: result.exitCode,
                output: result.combinedOutput
            )
        }
    }

    private nonisolated func progressRelay(
        stage: UpdateProgress.Stage,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) -> (@Sendable (String) -> Void)? {
        guard let onProgress else { return nil }
        return { chunk in
            let message = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            onProgress(UpdateProgress(
                stage: stage,
                packageName: Self.packageNameFromProgressOutput(message),
                message: message
            ))
        }
    }

    private nonisolated static func packageNameFromProgressOutput(_ output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for prefix in ["==> Upgrading ", "==> Reinstalling Cask "] where line.hasPrefix(prefix) {
                return line.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
            }
        }
        return nil
    }

    private nonisolated static func deduplicated(
        _ packages: [HomebrewPackage]
    ) -> [HomebrewPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }
}
