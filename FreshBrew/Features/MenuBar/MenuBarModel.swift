import Combine
import Foundation

@MainActor
final class MenuBarModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case checking
        case updating
        case cleaning
    }

    static let unlockCheckDelay: TimeInterval = 60
    static let minimumHomebrewCheckInterval: TimeInterval = 14_400

    @Published private(set) var availablePackages: [HomebrewPackage] = []
    @Published private(set) var updateHistory: [UpdateHistoryEntry]
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var progress: UpdateProgress?
    @Published private(set) var statusMessage = "FreshBrew is ready"
    @Published private(set) var lastSuccessfulHomebrewCheckDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var packageHomepageErrorMessage: String?
    @Published private(set) var sessionSkippedPackageIDs = Set<String>()
    @Published private(set) var rememberedSkippedPackageIDs: Set<String>
    @Published private(set) var restartRequired = false

    @Published var greedyModeEnabled: Bool {
        didSet {
            guard greedyModeEnabled != oldValue else { return }
            preferences.greedyModeEnabled = greedyModeEnabled
            availablePackages = []
            sessionSkippedPackageIDs = []
            lastSuccessfulHomebrewCheckDate = nil
            preferences.lastSuccessfulHomebrewCheckDate = nil
            packageHomepageErrorMessage = nil
            statusMessage = "FreshBrew is ready"
        }
    }

    @Published var automaticCheckMode: AutomaticCheckMode {
        didSet {
            guard automaticCheckMode != oldValue else { return }
            preferences.automaticCheckMode = automaticCheckMode
            configureAutomaticChecksIfStarted()
        }
    }

    @Published private(set) var periodicCheckInterval: TimeInterval

    @Published var autoCleanupEnabled: Bool {
        didSet { preferences.autoCleanupEnabled = autoCleanupEnabled }
    }

    @Published private(set) var launchAtLoginEnabled: Bool

    var isRunning: Bool {
        activity != .idle
    }

    var visiblePackages: [HomebrewPackage] {
        let skippedIDs = sessionSkippedPackageIDs.union(rememberedSkippedPackageIDs)
        return availablePackages.filter { !skippedIDs.contains($0.id) }
    }

    var latestUpdate: UpdateHistoryEntry? {
        updateHistory.first
    }

    var checkUpdatesLabel: String {
        greedyModeEnabled ? "Check Updates (Greedy)" : "Check Updates"
    }

    var updateAllLabel: String {
        greedyModeEnabled ? "Update All (Greedy)" : "Update All"
    }

    var hasPendingUnlockCheck: Bool {
        pendingUnlockCheckTask != nil
    }

    private let homebrewService: any HomebrewServicing
    private let preferences: FreshBrewPreferences
    private let historyStore: UpdateHistoryStore
    private let packageHomepageStore: PackageHomepageStore
    private let errorLogStore: HomebrewErrorLogStore
    private let notificationService: any NotificationServing
    private let launchAtLoginService: any LaunchAtLoginServicing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var automaticChecksStarted = false
    private var pendingUnlockCheckTask: Task<Void, Never>?
    private var periodicCheckTask: Task<Void, Never>?
    private var pendingUpdateKnownPackageIDs: Set<String>?
    private var pendingCompletedPackages: [UpdatedPackage] = []
    private var pendingVerificationUnavailable = false
    private var pendingRestartRequired = false

    init(
        homebrewService: any HomebrewServicing = HomebrewService(),
        preferences: FreshBrewPreferences = FreshBrewPreferences(),
        historyStore: UpdateHistoryStore = UpdateHistoryStore(),
        packageHomepageStore: PackageHomepageStore = PackageHomepageStore(),
        errorLogStore: HomebrewErrorLogStore = HomebrewErrorLogStore(),
        notificationService: any NotificationServing = NoopNotificationService(),
        launchAtLoginService: (any LaunchAtLoginServicing)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.homebrewService = homebrewService
        self.preferences = preferences
        self.historyStore = historyStore
        self.packageHomepageStore = packageHomepageStore
        self.errorLogStore = errorLogStore
        self.notificationService = notificationService
        let resolvedLaunchAtLoginService = launchAtLoginService ?? LaunchAtLoginService()
        self.launchAtLoginService = resolvedLaunchAtLoginService
        self.now = now
        self.sleep = sleep
        greedyModeEnabled = preferences.greedyModeEnabled
        automaticCheckMode = preferences.automaticCheckMode
        periodicCheckInterval = max(60, preferences.periodicCheckInterval)
        autoCleanupEnabled = preferences.autoCleanupEnabled
        launchAtLoginEnabled = resolvedLaunchAtLoginService.isEnabled
        rememberedSkippedPackageIDs = preferences.rememberedSkippedPackageIDs
        updateHistory = Self.attachingHomepageURLs(
            to: historyStore.load(),
            store: packageHomepageStore
        )
        lastSuccessfulHomebrewCheckDate = preferences.lastSuccessfulHomebrewCheckDate
        preferences.launchAtLoginEnabled = launchAtLoginEnabled
    }

    func checkUpdates(
        respectMinimumInterval: Bool = false
    ) async -> Bool {
        guard !isRunning else { return false }
        if respectMinimumInterval, !shouldRunHomebrewCheck() {
            return false
        }

        activity = .checking
        progress = nil
        statusMessage = "Checking updates…"
        lastErrorMessage = nil
        packageHomepageErrorMessage = nil

        defer {
            activity = .idle
            progress = nil
        }

        do {
            let packages = try await homebrewService.checkOutdated(
                greedy: greedyModeEnabled,
                refreshMetadata: true
            )
            let successfulCheckDate = now()
            lastSuccessfulHomebrewCheckDate = successfulCheckDate
            preferences.lastSuccessfulHomebrewCheckDate = successfulCheckDate
            let homepageURLs = await homebrewService.packageHomepageURLs(for: packages)
            packageHomepageStore.save(homepageURLs)
            availablePackages = attachHomepageURLs(to: packages)
            sessionSkippedPackageIDs = []
            statusMessage = "FreshBrew is ready"
            await notificationService.postUpdatesAvailable(count: visiblePackages.count)
            return true
        } catch {
            await handleFailure(
                error,
                operation: "check updates",
                status: Self.failureStatus(
                    for: error,
                    fallback: "Check failed",
                    timeout: "Check timed out"
                )
            )
            await notificationService.postCheckFailure(
                message: lastErrorMessage ?? "Homebrew could not complete the update check."
            )
            return false
        }
    }

    func updateAll() async -> UpdateResult? {
        await update(packages: visiblePackages)
    }

    func update(package: HomebrewPackage) async -> UpdateResult? {
        await update(packages: [package])
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard enabled != launchAtLoginEnabled else { return }
        do {
            try launchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = launchAtLoginService.isEnabled
            preferences.launchAtLoginEnabled = launchAtLoginEnabled
            lastErrorMessage = nil
        } catch {
            launchAtLoginEnabled = launchAtLoginService.isEnabled
            preferences.launchAtLoginEnabled = launchAtLoginEnabled
            lastErrorMessage = error.localizedDescription
            statusMessage = "Setting change failed"
        }
    }

    func reportPackageHomepageOpenFailure() {
        packageHomepageErrorMessage = "Could not open package homepage"
    }

    func reportPackageHomepageOpened() {
        packageHomepageErrorMessage = nil
    }

    func reportRestartFailure(_ message: String) {
        lastErrorMessage = message
        statusMessage = "Restart failed"
    }

    func cachedPackageHomepageURL(for packageID: String) -> URL? {
        packageHomepageStore.url(for: packageID)
    }

    func setPeriodicCheckInterval(_ interval: TimeInterval) {
        let normalizedInterval = max(60, interval)
        guard periodicCheckInterval != normalizedInterval else { return }
        periodicCheckInterval = normalizedInterval
        preferences.periodicCheckInterval = normalizedInterval
        configureAutomaticChecksIfStarted()
    }

    func cleanup(deep: Bool) async -> CleanupResult? {
        guard !isRunning else { return nil }
        activity = .cleaning
        statusMessage = "Cleaning up…"
        lastErrorMessage = nil
        packageHomepageErrorMessage = nil
        defer { activity = .idle }

        do {
            let result = try await homebrewService.cleanup(deep: deep)
            statusMessage = "FreshBrew is ready"
            if result.freedSpaceDescription != nil {
                await notificationService.postCleanupResult(result)
            }
            return result
        } catch {
            await handleFailure(
                error,
                operation: deep ? "deep cleanup" : "cleanup",
                status: Self.failureStatus(
                    for: error,
                    fallback: "Cleanup failed",
                    timeout: "Cleanup timed out"
                )
            )
            await notificationService.postCleanupFailure(
                deep: deep,
                message: lastErrorMessage ?? "Homebrew could not complete the cleanup."
            )
            return nil
        }
    }

    func skip(_ package: HomebrewPackage, remember: Bool) {
        sessionSkippedPackageIDs.insert(package.id)
        if remember {
            if let homepageURL = package.homepageURL {
                packageHomepageStore.save([package.id: homepageURL])
            }
            rememberedSkippedPackageIDs.insert(package.id)
            preferences.rememberedSkippedPackageIDs = rememberedSkippedPackageIDs
        }
    }

    func forgetSkippedPackage(id: String) {
        rememberedSkippedPackageIDs.remove(id)
        preferences.rememberedSkippedPackageIDs = rememberedSkippedPackageIDs
    }

    func clearRememberedSkippedPackages() {
        rememberedSkippedPackageIDs = []
        preferences.rememberedSkippedPackageIDs = []
    }

    func startAutomaticChecks() {
        guard !automaticChecksStarted else { return }
        automaticChecksStarted = true
        configureAutomaticChecksIfStarted()
    }

    func stopAutomaticChecks() {
        automaticChecksStarted = false
        cancelPendingUnlockCheck()
        periodicCheckTask?.cancel()
        periodicCheckTask = nil
    }

    func scheduleCheckAfterUnlock(at date: Date? = nil) {
        cancelPendingUnlockCheck()
        guard automaticChecksStarted,
              automaticCheckMode == .afterUnlock,
              shouldRunHomebrewCheck(now: date ?? now()) else {
            return
        }

        let sleep = self.sleep
        pendingUnlockCheckTask = Task { [weak self] in
            do {
                try await sleep(Self.unlockCheckDelay)
                try Task.checkCancellation()
            } catch {
                return
            }

            guard let self else { return }
            self.pendingUnlockCheckTask = nil
            guard self.automaticCheckMode == .afterUnlock,
                  self.shouldRunHomebrewCheck() else {
                return
            }
            _ = await self.checkUpdates(respectMinimumInterval: true)
        }
    }

    func shouldRunHomebrewCheck(now date: Date? = nil) -> Bool {
        let checkDate = date ?? now()
        if let lastSuccessDate = preferences.lastSuccessfulHomebrewCheckDate,
           checkDate.timeIntervalSince(lastSuccessDate)
            < Self.minimumHomebrewCheckInterval {
            return false
        }
        return true
    }

    private func update(
        packages: [HomebrewPackage]
    ) async -> UpdateResult? {
        guard !isRunning, !packages.isEmpty else { return nil }
        let currentKnownPackageIDs = Set((availablePackages + packages).map(\.id))
        resetPendingUpdateWorkflow()
        pendingUpdateKnownPackageIDs = currentKnownPackageIDs
        activity = .updating
        statusMessage = "Updating \(packages.count) package\(packages.count == 1 ? "" : "s")…"
        lastErrorMessage = nil
        packageHomepageErrorMessage = nil
        progress = nil

        defer {
            activity = .idle
            progress = nil
        }

        do {
            let freshBrewPackage = packages.first(where: \.isFreshBrewCask)
            let otherPackages = packages.filter { !$0.isFreshBrewCask }
            var phaseResults: [UpdateResult] = []

            if !otherPackages.isEmpty {
                let result = try await runUpdatePhase(packages: otherPackages)
                phaseResults.append(result)
                await applyUpdateResult(result)

                // FreshBrew must remain the final phase. If the earlier phase
                // fails or cannot be verified, leave FreshBrew untouched.
                if result.hasFailures {
                    applyUpdateFailureStatus(result)
                    await finalizePendingUpdateWorkflow(hadFailures: true)
                    return Self.combinedUpdateResult(phaseResults)
                }
            }

            if let freshBrewPackage {
                let result = try await runFreshBrewUpdatePhase(freshBrewPackage)
                phaseResults.append(result)
                await applyUpdateResult(result)
            }

            guard let combinedResult = Self.combinedUpdateResult(phaseResults) else {
                return nil
            }
            if combinedResult.hasFailures {
                applyUpdateFailureStatus(combinedResult)
            }
            await finalizePendingUpdateWorkflow(hadFailures: combinedResult.hasFailures)
            return combinedResult
        } catch {
            await handleFailure(
                error,
                operation: "update packages",
                status: Self.failureStatus(
                    for: error,
                    fallback: "Update failed",
                    timeout: "Update timed out"
                )
            )
            await finalizePendingUpdateWorkflow(hadFailures: true)
            return nil
        }
    }

    private func resetPendingUpdateWorkflow() {
        pendingUpdateKnownPackageIDs = nil
        pendingCompletedPackages = []
        pendingVerificationUnavailable = false
        pendingRestartRequired = false
    }

    private func runUpdatePhase(
        packages: [HomebrewPackage]
    ) async throws -> UpdateResult {
        try await homebrewService.update(
            packages: packages,
            greedy: greedyModeEnabled,
            onProgress: progressHandler
        )
    }

    private func runFreshBrewUpdatePhase(
        _ package: HomebrewPackage
    ) async throws -> UpdateResult {
        try await homebrewService.updateFreshBrew(
            package: package,
            greedy: greedyModeEnabled,
            onProgress: progressHandler
        )
    }

    private var progressHandler: @Sendable (UpdateProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                self?.progress = progress
            }
        }
    }

    private func applyUpdateResult(_ result: UpdateResult) async {
        if result.verification.failure == nil {
            availablePackages = attachHomepageURLs(to: result.remainingPackages)
        } else {
            pendingVerificationUnavailable = true
        }

        let completedPackages = attachHomepageURLs(to: result.completedPackages)
        mergePendingCompletedPackages(completedPackages)
        if completedPackages.contains(where: { $0.id == HomebrewPackage.freshBrewCaskID }) {
            pendingRestartRequired = true
            restartRequired = true
        }

        if let verificationFailure = result.verification.failure {
            try? await errorLogStore.record(
                operation: verificationFailure.operation,
                output: verificationFailure.output,
                timestamp: result.timestamp
            )
        }
        for failure in result.failures {
            try? await errorLogStore.record(
                operation: failure.operation,
                output: failure.output,
                timestamp: result.timestamp
            )
        }
    }

    private func applyUpdateFailureStatus(_ result: UpdateResult) {
        if result.verification.failure != nil {
            statusMessage = "Verification failed"
            lastErrorMessage = "FreshBrew could not verify the remaining updates."
            return
        }

        let failureCount = result.failures.count
        let didTimeOut = result.failures.contains { $0.kind == .timeout }
        statusMessage = didTimeOut ? "Update timed out" : "Update failed"
        lastErrorMessage = didTimeOut
            ? "A package update exceeded its time limit."
            : "\(failureCount) update operation\(failureCount == 1 ? "" : "s") failed"
    }

    private static func combinedUpdateResult(
        _ results: [UpdateResult]
    ) -> UpdateResult? {
        guard let finalResult = results.last else { return nil }
        var completedPackages: [UpdatedPackage] = []
        var completedIDs = Set<String>()
        for package in results.flatMap(\.completedPackages) {
            if completedIDs.insert(package.id).inserted {
                completedPackages.append(package)
            }
        }
        return UpdateResult(
            completedPackages: completedPackages,
            remainingPackages: finalResult.remainingPackages,
            failures: results.flatMap(\.failures),
            timestamp: finalResult.timestamp,
            verification: finalResult.verification
        )
    }

    private func mergePendingCompletedPackages(_ packages: [UpdatedPackage]) {
        for package in packages {
            if let index = pendingCompletedPackages.firstIndex(where: { $0.id == package.id }) {
                pendingCompletedPackages[index] = package
            } else {
                pendingCompletedPackages.append(package)
            }
        }
    }

    private func attachHomepageURLs(
        to packages: [HomebrewPackage]
    ) -> [HomebrewPackage] {
        packages.map { package in
            HomebrewPackage(
                name: package.name,
                installedVersion: package.installedVersion,
                availableVersion: package.availableVersion,
                kind: package.kind,
                homepageURL: package.homepageURL
                    ?? packageHomepageStore.url(for: package.id)
            )
        }
    }

    private func attachHomepageURLs(
        to packages: [UpdatedPackage]
    ) -> [UpdatedPackage] {
        packages.map { package in
            UpdatedPackage(
                name: package.name,
                previousVersion: package.previousVersion,
                installedVersion: package.installedVersion,
                kind: package.kind,
                homepageURL: package.homepageURL
                    ?? packageHomepageStore.url(for: package.id)
            )
        }
    }

    private static func attachingHomepageURLs(
        to history: [UpdateHistoryEntry],
        store: PackageHomepageStore
    ) -> [UpdateHistoryEntry] {
        history.map { entry in
            UpdateHistoryEntry(
                id: entry.id,
                packages: entry.packages.map { package in
                    UpdatedPackage(
                        name: package.name,
                        previousVersion: package.previousVersion,
                        installedVersion: package.installedVersion,
                        kind: package.kind,
                        homepageURL: package.homepageURL
                            ?? store.url(for: package.id)
                    )
                },
                timestamp: entry.timestamp
            )
        }
    }

    private func finalizePendingUpdateWorkflow(hadFailures: Bool) async {
        let completedPackages = pendingCompletedPackages
        let knownPackageIDs = pendingUpdateKnownPackageIDs ?? []
        let verificationUnavailable = pendingVerificationUnavailable
        let restartRequired = pendingRestartRequired
        let newlyAvailableCount = verificationUnavailable ? 0 : visiblePackages.filter {
            !knownPackageIDs.contains($0.id)
        }.count
        var cleanupOutcome: UpdateCleanupOutcome?

        if !completedPackages.isEmpty {
            updateHistory = historyStore.append(
                packages: completedPackages,
                timestamp: now()
            )
        }

        if !hadFailures, autoCleanupEnabled, !completedPackages.isEmpty {
            activity = .cleaning
            statusMessage = "Cleaning up…"
            do {
                let cleanupResult = try await homebrewService.cleanup(deep: false)
                cleanupOutcome = .completed(
                    freedSpace: cleanupResult.freedSpaceDescription
                )
                statusMessage = "FreshBrew is ready"
            } catch {
                cleanupOutcome = .failed
                await handleFailure(
                    error,
                    operation: "automatic cleanup",
                    status: Self.failureStatus(
                        for: error,
                        fallback: "Cleanup failed",
                        timeout: "Cleanup timed out"
                    )
                )
            }
        } else if !hadFailures {
            statusMessage = "FreshBrew is ready"
        }

        await notificationService.postUpdateResult(
            updatedCount: completedPackages.count,
            remainingUpdateCount: visiblePackages.count,
            hadFailures: hadFailures,
            newlyAvailableCount: newlyAvailableCount,
            cleanupOutcome: cleanupOutcome,
            verificationUnavailable: verificationUnavailable,
            restartRequired: restartRequired
        )
        resetPendingUpdateWorkflow()
    }

    private func handleFailure(
        _ error: Error,
        operation: String,
        status: String
    ) async {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let output = Self.diagnosticOutput(for: error)
        lastErrorMessage = message
        statusMessage = status
        try? await errorLogStore.record(
            operation: operation,
            output: output,
            timestamp: now()
        )
    }

    private static func diagnosticOutput(for error: Error) -> String {
        guard let homebrewError = error as? HomebrewError else {
            return String(describing: error)
        }

        switch homebrewError {
        case let .commandFailed(failure):
            return failure.output
        case let .permissionRequired(output):
            return output
        case let .existingApplicationConflict(_, output):
            return output
        case let .executableNotFound(url), let .invalidRecoveryTarget(url):
            return url.path
        case .networkUnavailable:
            return "No network connection is available."
        case let .timedOut(operation, seconds, output):
            let timeoutDescription = "FreshBrew stopped \(operation) after \(Int(seconds)) seconds."
            return [output, timeoutDescription]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private static func failureStatus(
        for error: Error,
        fallback: String,
        timeout: String
    ) -> String {
        guard let homebrewError = error as? HomebrewError else { return fallback }
        if homebrewError.indicatesNetworkFailure {
            return "Network unavailable"
        }
        switch homebrewError {
        case .timedOut:
            return timeout
        default:
            return fallback
        }
    }

    private func configureAutomaticChecksIfStarted() {
        guard automaticChecksStarted else { return }
        cancelPendingUnlockCheck()
        periodicCheckTask?.cancel()
        periodicCheckTask = nil

        guard automaticCheckMode == .periodic else { return }
        let interval = periodicCheckInterval
        let sleep = self.sleep
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard let self else { return }
                _ = await self.checkUpdates(respectMinimumInterval: false)
            }
        }
    }

    private func cancelPendingUnlockCheck() {
        pendingUnlockCheckTask?.cancel()
        pendingUnlockCheckTask = nil
    }
}
