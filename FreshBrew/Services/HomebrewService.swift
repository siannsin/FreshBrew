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

enum HomebrewHostArchitecture: Equatable, Sendable {
    case appleSilicon
    case intel

    nonisolated static var current: HomebrewHostArchitecture {
#if arch(arm64)
        .appleSilicon
#elseif arch(x86_64)
        .intel
#else
        .appleSilicon
#endif
    }
}

struct HomebrewExecutableLocator: Sendable {
    nonisolated static let appleSiliconURL = URL(
        fileURLWithPath: "/opt/homebrew/bin/brew"
    )
    nonisolated static let intelURL = URL(
        fileURLWithPath: "/usr/local/bin/brew"
    )

    nonisolated static func candidateURLs(
        for architecture: HomebrewHostArchitecture
    ) -> [URL] {
        switch architecture {
        case .appleSilicon:
            [appleSiliconURL, intelURL]
        case .intel:
            [intelURL, appleSiliconURL]
        }
    }

    nonisolated static func executableURL(
        for architecture: HomebrewHostArchitecture = .current,
        isExecutable: @Sendable (URL) -> Bool
    ) -> URL {
        let candidates = candidateURLs(for: architecture)
        return candidates.first(where: isExecutable) ?? candidates[0]
    }
}

private struct HomebrewOutdatedResponse: Decodable, Sendable {
    struct Formula: Decodable, Sendable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String

        private enum CodingKeys: String, CodingKey {
            case name
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
        }
    }

    struct Cask: Decodable, Sendable {
        let name: String
        let installedVersions: [String]
        let currentVersion: String

        private enum CodingKeys: String, CodingKey {
            case name
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
        }
    }

    let formulae: [Formula]
    let casks: [Cask]
}

private enum HomebrewOutdatedJSONError: LocalizedError {
    case emptyName(HomebrewPackageKind)
    case missingInstalledVersion(HomebrewPackageKind, String)
    case emptyCurrentVersion(HomebrewPackageKind, String)

    var errorDescription: String? {
        switch self {
        case let .emptyName(kind):
            "Homebrew returned an unnamed outdated \(kind.rawValue)."
        case let .missingInstalledVersion(kind, name):
            "Homebrew returned no installed version for \(kind.rawValue) \(name)."
        case let .emptyCurrentVersion(kind, name):
            "Homebrew returned no current version for \(kind.rawValue) \(name)."
        }
    }
}

actor HomebrewService {
    static let metadataTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 60)
    static let outdatedTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 30)
    static let homepageTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 5)
    static let packageTimeoutPolicy = CommandTimeoutPolicy(
        absoluteLimit: 30 * 60,
        inactivityLimit: 5 * 60
    )
    static let cleanupTimeoutPolicy = CommandTimeoutPolicy(absoluteLimit: 5 * 60)

    private let executableURL: URL
    private let runner: any CommandRunning
    private let executableIsAvailable: @Sendable (URL) -> Bool
    private let networkAvailabilityChecker: any NetworkAvailabilityChecking
    private let authorizationContext: AdminAuthorizationContext?

    init(
        executableURL: URL? = nil,
        runner: any CommandRunning = SystemCommandRunner(),
        networkAvailabilityChecker: any NetworkAvailabilityChecking = SystemNetworkAvailabilityChecker(),
        authorizationContext: AdminAuthorizationContext? = nil,
        executableIsAvailable: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    ) {
        self.executableURL = executableURL ?? HomebrewExecutableLocator.executableURL(
            isExecutable: executableIsAvailable
        )
        self.runner = runner
        self.networkAvailabilityChecker = networkAvailabilityChecker
        self.executableIsAvailable = executableIsAvailable
        self.authorizationContext = authorizationContext ?? AdminAuthorizationContext.bundled()
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
            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"],
            operation: "check outdated packages",
            timeoutPolicy: Self.outdatedTimeoutPolicy
        )
        try requireSuccess(outdatedResult, operation: "check outdated packages")
        do {
            return try Self.parseOutdatedJSON(outdatedResult.standardOutput)
        } catch {
            let decodingDetail = "FreshBrew could not decode Homebrew's outdated JSON: \(error)"
            throw HomebrewError.commandFailed(HomebrewCommandFailure(
                operation: "decode outdated packages",
                exitCode: outdatedResult.exitCode,
                output: [outdatedResult.combinedOutput, decodingDetail]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            ))
        }
    }

    func packageHomepageURL(
        packageName: String,
        kind: HomebrewPackageKind
    ) async throws -> URL {
        try ensureExecutableIsAvailable()

        let kindArgument = kind == .formula ? "--formula" : "--cask"
        let result = try await run(
            arguments: ["info", "--json=v2", kindArgument, packageName],
            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"],
            operation: "read package information",
            timeoutPolicy: Self.homepageTimeoutPolicy
        )
        try requireSuccess(result, operation: "read package information")
        return try Self.parsePackageHomepageURL(
            from: result.standardOutput,
            kind: kind
        )
    }

    func packageHomepageURLs(
        for packages: [HomebrewPackage]
    ) async -> [String: URL] {
        let groups = HomebrewPackageKind.allCases.compactMap { kind -> (HomebrewPackageKind, [String])? in
            let names = packages
                .filter { $0.kind == kind }
                .map(\.name)
            return names.isEmpty ? nil : (kind, names)
        }

        return await withTaskGroup(of: [String: URL].self) { group in
            for (kind, names) in groups {
                group.addTask { [self] in
                    await packageHomepageURLs(names: names, kind: kind)
                }
            }

            var urls: [String: URL] = [:]
            for await result in group {
                urls.merge(result) { _, latest in latest }
            }
            return urls
        }
    }

    func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)? = nil
    ) async throws -> UpdateResult {
        try await update(
            packages: packages,
            greedy: greedy,
            keepsFreshBrewRunning: false,
            onProgress: onProgress
        )
    }

    func updateFreshBrew(
        package: HomebrewPackage,
        greedy: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)? = nil
    ) async throws -> UpdateResult {
        guard package.isFreshBrewCask else {
            throw HomebrewError.commandFailed(HomebrewCommandFailure(
                operation: "update FreshBrew",
                exitCode: -1,
                output: "FreshBrew self-update requires cask:freshbrew."
            ))
        }
        return try await update(
            packages: [package],
            greedy: greedy,
            keepsFreshBrewRunning: true,
            onProgress: onProgress
        )
    }

    private func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        keepsFreshBrewRunning: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
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

        let environment = authorizationContext?.environment ?? [:]
        var commandFailures: [HomebrewCommandFailure] = []
        var combinedUpgradeOutput = ""
        var evidencedCompletedPackageIDs = Set<String>()
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
                    arguments: Self.upgradeArguments(
                        for: group,
                        greedy: greedy,
                        keepsFreshBrewRunning: keepsFreshBrewRunning
                    ),
                    environment: environment,
                    operation: operation,
                    timeoutPolicy: Self.packageTimeoutPolicy,
                    onOutput: progressRelay(stage: .upgrading, onProgress: onProgress)
                )
                combinedUpgradeOutput += "\n" + result.combinedOutput

                if result.exitCode == 0 {
                    evidencedCompletedPackageIDs.formUnion(group.map(\.id))
                } else {
                    commandFailures.append(HomebrewCommandFailure(
                        operation: operation,
                        exitCode: result.exitCode,
                        output: result.combinedOutput
                    ))
                }
            } catch let error as HomebrewError {
                guard let failure = Self.timeoutFailure(from: error) else { throw error }
                commandFailures.append(failure)
                combinedUpgradeOutput += "\n" + failure.output
                updateTimedOut = true
                break
            }
        }

        let refusedNames = Set(Self.casksNeedingForcedReinstall(from: combinedUpgradeOutput))
        let refusedCasks = updateTimedOut ? [] : candidates.filter {
            $0.kind == .cask && refusedNames.contains($0.name)
        }
        evidencedCompletedPackageIDs.subtract(refusedCasks.map(\.id))

        for package in refusedCasks {
            onProgress?(UpdateProgress(
                stage: .reinstalling,
                packageName: package.name,
                message: "Reinstalling \(package.name)"
            ))

            let operation = "force reinstall \(package.name)"
            do {
                var reinstallArguments = ["reinstall", "--cask", "--force"]
                if keepsFreshBrewRunning, package.isFreshBrewCask {
                    reinstallArguments.append("--no-quit")
                }
                reinstallArguments.append(package.name)
                let reinstallResult = try await run(
                    arguments: reinstallArguments,
                    environment: environment,
                    operation: operation,
                    timeoutPolicy: Self.packageTimeoutPolicy,
                    onOutput: progressRelay(stage: .reinstalling, onProgress: onProgress)
                )
                combinedUpgradeOutput += "\n" + reinstallResult.combinedOutput
                if reinstallResult.exitCode == 0 {
                    evidencedCompletedPackageIDs.insert(package.id)
                } else {
                    commandFailures.append(HomebrewCommandFailure(
                        operation: operation,
                        exitCode: reinstallResult.exitCode,
                        output: reinstallResult.combinedOutput
                    ))
                }
            } catch let error as HomebrewError {
                guard let failure = Self.timeoutFailure(from: error) else { throw error }
                commandFailures.append(failure)
                combinedUpgradeOutput += "\n" + failure.output
                break
            }
        }

        onProgress?(UpdateProgress(
            stage: .verifying,
            packageName: nil,
            message: "Verifying Homebrew updates"
        ))

        let remainingPackages: [HomebrewPackage]
        do {
            remainingPackages = try await checkOutdated(
                greedy: greedy,
                refreshMetadata: false
            )
        } catch {
            let completedPackages = candidates.compactMap { package -> UpdatedPackage? in
                guard evidencedCompletedPackageIDs.contains(package.id) else { return nil }
                return Self.updatedPackage(from: package)
            }
            return UpdateResult(
                completedPackages: completedPackages,
                remainingPackages: candidates.filter {
                    !evidencedCompletedPackageIDs.contains($0.id)
                },
                failures: commandFailures,
                timestamp: Date(),
                verification: .unavailable(Self.verificationFailure(from: error))
            )
        }
        let remainingIDs = Set(remainingPackages.map(\.id))
        let completedPackages = candidates.compactMap { package -> UpdatedPackage? in
            guard !remainingIDs.contains(package.id) else { return nil }
            return Self.updatedPackage(from: package)
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

            let remainingPackages: [HomebrewPackage]
            do {
                remainingPackages = try await checkOutdated(
                    greedy: greedy,
                    refreshMetadata: false
                )
            } catch {
                return UpdateResult(
                    completedPackages: [Self.updatedPackage(from: package)],
                    remainingPackages: [],
                    failures: [],
                    timestamp: Date(),
                    verification: .unavailable(Self.verificationFailure(from: error))
                )
            }
            let isStillOutdated = remainingPackages.contains { $0.id == package.id }
            let completedPackages = isStillOutdated ? [] : [Self.updatedPackage(from: package)]
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
        var arguments = ["outdated", "--json=v2"]
        if greedy {
            arguments.append("--greedy")
        }
        return arguments
    }

    nonisolated static func upgradeArguments(
        for packages: [HomebrewPackage],
        greedy: Bool,
        keepsFreshBrewRunning: Bool = false
    ) -> [String] {
        guard let kind = packages.first?.kind else { return [] }
        var arguments = ["upgrade", kind == .cask ? "--cask" : "--formula"]
        if greedy, kind == .cask {
            arguments.append("--greedy")
        }
        if keepsFreshBrewRunning,
           packages.count == 1,
           packages[0].isFreshBrewCask {
            arguments.append("--no-quit")
        }
        arguments.append(contentsOf: packages.map(\.name))
        return arguments
    }

    nonisolated static func parseOutdatedJSON(_ output: String) throws -> [HomebrewPackage] {
        let response = try JSONDecoder().decode(
            HomebrewOutdatedResponse.self,
            from: Data(output.utf8)
        )

        let formulae = try response.formulae.map {
            try outdatedPackage(
                name: $0.name,
                installedVersions: $0.installedVersions,
                currentVersion: $0.currentVersion,
                kind: .formula
            )
        }
        let casks = try response.casks.map {
            try outdatedPackage(
                name: $0.name,
                installedVersions: $0.installedVersions,
                currentVersion: $0.currentVersion,
                kind: .cask
            )
        }
        return formulae + casks
    }

    private nonisolated static func outdatedPackage(
        name: String,
        installedVersions: [String],
        currentVersion: String,
        kind: HomebrewPackageKind
    ) throws -> HomebrewPackage {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw HomebrewOutdatedJSONError.emptyName(kind)
        }

        let installedVersions = installedVersions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !installedVersions.isEmpty,
              installedVersions.allSatisfy({ !$0.isEmpty }) else {
            throw HomebrewOutdatedJSONError.missingInstalledVersion(kind, name)
        }

        let currentVersion = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentVersion.isEmpty else {
            throw HomebrewOutdatedJSONError.emptyCurrentVersion(kind, name)
        }

        return HomebrewPackage(
            name: name,
            installedVersion: installedVersions.joined(separator: ", "),
            availableVersion: currentVersion,
            kind: kind
        )
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

    nonisolated static func parsePackageHomepageURL(
        from output: String,
        kind: HomebrewPackageKind
    ) throws -> URL {
        struct PackageInfoResponse: Decodable {
            struct PackageInfo: Decodable {
                let homepage: String?
            }

            let formulae: [PackageInfo]
            let casks: [PackageInfo]
        }

        let data = Data(output.utf8)
        guard let response = try? JSONDecoder().decode(PackageInfoResponse.self, from: data) else {
            throw PackageHomepageError.unavailable
        }

        let homepage = switch kind {
        case .formula:
            response.formulae.first?.homepage
        case .cask:
            response.casks.first?.homepage
        }

        guard let homepage,
              !homepage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PackageHomepageError.unavailable
        }

        guard let url = validatedHomepageURL(homepage) else {
            throw PackageHomepageError.invalidURL(homepage)
        }

        return url
    }

    nonisolated static func parsePackageHomepageURLs(
        from output: String,
        kind: HomebrewPackageKind
    ) -> [String: URL] {
        struct PackageInfoResponse: Decodable {
            struct FormulaInfo: Decodable {
                let name: String
                let homepage: String?
            }

            struct CaskInfo: Decodable {
                let token: String
                let homepage: String?
            }

            let formulae: [FormulaInfo]
            let casks: [CaskInfo]
        }

        guard let response = try? JSONDecoder().decode(
            PackageInfoResponse.self,
            from: Data(output.utf8)
        ) else {
            return [:]
        }

        let values: [(String, String?)] = switch kind {
        case .formula:
            response.formulae.map { ($0.name, $0.homepage) }
        case .cask:
            response.casks.map { ($0.token, $0.homepage) }
        }

        var urls: [String: URL] = [:]
        for (name, homepage) in values {
            guard let homepage,
                  let url = validatedHomepageURL(homepage) else {
                continue
            }
            urls["\(kind.rawValue):\(name)"] = url
        }
        return urls
    }

    nonisolated private static func validatedHomepageURL(_ homepage: String) -> URL? {
        let normalizedHomepage = homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalizedHomepage),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    private func packageHomepageURLs(
        names: [String],
        kind: HomebrewPackageKind
    ) async -> [String: URL] {
        do {
            try ensureExecutableIsAvailable()
            let kindArgument = kind == .formula ? "--formula" : "--cask"
            let result = try await run(
                arguments: ["info", "--json=v2", kindArgument] + names,
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"],
                operation: "read package information",
                timeoutPolicy: Self.homepageTimeoutPolicy
            )
            guard result.exitCode == 0 else { return [:] }
            return Self.parsePackageHomepageURLs(
                from: result.standardOutput,
                kind: kind
            )
        } catch {
            return [:]
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

    private nonisolated static func verificationFailure(
        from error: Error
    ) -> HomebrewCommandFailure {
        if let homebrewError = error as? HomebrewError {
            switch homebrewError {
            case let .commandFailed(failure):
                return HomebrewCommandFailure(
                    operation: "verify updates",
                    exitCode: failure.exitCode,
                    output: failure.output,
                    kind: failure.kind
                )
            case let .timedOut(_, seconds, output):
                let detail = "FreshBrew stopped update verification after \(Int(seconds)) seconds."
                return HomebrewCommandFailure(
                    operation: "verify updates",
                    exitCode: -1,
                    output: [output, detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                    kind: .timeout
                )
            case let .permissionRequired(output):
                return HomebrewCommandFailure(
                    operation: "verify updates",
                    exitCode: -1,
                    output: output
                )
            case let .existingApplicationConflict(_, output):
                return HomebrewCommandFailure(
                    operation: "verify updates",
                    exitCode: -1,
                    output: output
                )
            case let .executableNotFound(url), let .invalidRecoveryTarget(url):
                return HomebrewCommandFailure(
                    operation: "verify updates",
                    exitCode: -1,
                    output: url.path
                )
            case .networkUnavailable:
                return HomebrewCommandFailure(
                    operation: "verify updates",
                    exitCode: -1,
                    output: homebrewError.localizedDescription
                )
            }
        }

        return HomebrewCommandFailure(
            operation: "verify updates",
            exitCode: -1,
            output: String(describing: error)
        )
    }

    private nonisolated static func updatedPackage(
        from package: HomebrewPackage
    ) -> UpdatedPackage {
        UpdatedPackage(
            name: package.name,
            previousVersion: package.installedVersion,
            installedVersion: package.availableVersion,
            kind: package.kind,
            homepageURL: package.homepageURL
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
