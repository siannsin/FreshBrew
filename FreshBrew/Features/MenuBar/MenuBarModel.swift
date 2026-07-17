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
    @Published private(set) var lastHomebrewCheckDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var administratorAccessRequired = false
    @Published private(set) var sessionSkippedPackageIDs = Set<String>()
    @Published private(set) var rememberedSkippedPackageIDs: Set<String>

    @Published var greedyModeEnabled: Bool {
        didSet {
            guard greedyModeEnabled != oldValue else { return }
            preferences.greedyModeEnabled = greedyModeEnabled
            availablePackages = []
            sessionSkippedPackageIDs = []
            lastHomebrewCheckDate = nil
            preferences.lastHomebrewCheckDate = nil
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
    private let errorLogStore: HomebrewErrorLogStore
    private let notificationService: any NotificationServing
    private let launchAtLoginService: any LaunchAtLoginServicing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var automaticChecksStarted = false
    private var pendingUnlockCheckTask: Task<Void, Never>?
    private var periodicCheckTask: Task<Void, Never>?
    private var lastAttemptedPackages: [HomebrewPackage] = []

    init(
        homebrewService: any HomebrewServicing = HomebrewService(),
        preferences: FreshBrewPreferences = FreshBrewPreferences(),
        historyStore: UpdateHistoryStore = UpdateHistoryStore(),
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
        updateHistory = historyStore.load()
        lastHomebrewCheckDate = preferences.lastHomebrewCheckDate
        preferences.launchAtLoginEnabled = launchAtLoginEnabled
    }

    func checkUpdates(
        respectMinimumInterval: Bool = false,
        notifyIfAvailable: Bool = false
    ) async -> Bool {
        guard !isRunning else { return false }
        if respectMinimumInterval, !shouldRunHomebrewCheck() {
            return false
        }

        activity = .checking
        progress = nil
        statusMessage = "Checking updates…"
        lastErrorMessage = nil
        let checkDate = now()
        lastHomebrewCheckDate = checkDate
        preferences.lastHomebrewCheckDate = checkDate

        defer {
            activity = .idle
            progress = nil
        }

        do {
            let packages = try await homebrewService.checkOutdated(
                greedy: greedyModeEnabled,
                refreshMetadata: true
            )
            availablePackages = packages
            sessionSkippedPackageIDs = []
            statusMessage = "FreshBrew is ready"
            if notifyIfAvailable {
                await notificationService.postUpdatesAvailable(count: visiblePackages.count)
            }
            return true
        } catch {
            await handleFailure(
                error,
                operation: "check updates",
                status: "Check failed"
            )
            await notificationService.postCheckFailure(
                message: lastErrorMessage ?? "Homebrew could not complete the update check."
            )
            return false
        }
    }

    func updateAll(administratorPassword: String? = nil) async -> UpdateResult? {
        await update(
            packages: visiblePackages,
            administratorPassword: administratorPassword
        )
    }

    func update(
        package: HomebrewPackage,
        administratorPassword: String? = nil
    ) async -> UpdateResult? {
        await update(
            packages: [package],
            administratorPassword: administratorPassword
        )
    }

    func retryLastUpdate(administratorPassword: String) async -> UpdateResult? {
        guard administratorAccessRequired else { return nil }
        let remainingIDs = Set(availablePackages.map(\.id))
        let retryPackages = lastAttemptedPackages.filter { remainingIDs.contains($0.id) }
        guard !retryPackages.isEmpty else {
            administratorAccessRequired = false
            return nil
        }
        return await update(
            packages: retryPackages,
            administratorPassword: administratorPassword,
            isAdministratorRetry: true
        )
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
        defer { activity = .idle }

        do {
            let result = try await homebrewService.cleanup(deep: deep)
            statusMessage = "FreshBrew is ready"
            return result
        } catch {
            await handleFailure(
                error,
                operation: deep ? "deep cleanup" : "cleanup",
                status: "Cleanup failed"
            )
            return nil
        }
    }

    func skip(_ package: HomebrewPackage, remember: Bool) {
        sessionSkippedPackageIDs.insert(package.id)
        if remember {
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
            _ = await self.checkUpdates(
                respectMinimumInterval: true,
                notifyIfAvailable: true
            )
        }
    }

    func shouldRunHomebrewCheck(now date: Date? = nil) -> Bool {
        guard let lastCheckDate = preferences.lastHomebrewCheckDate else {
            return true
        }
        return (date ?? now()).timeIntervalSince(lastCheckDate)
            >= Self.minimumHomebrewCheckInterval
    }

    private func update(
        packages: [HomebrewPackage],
        administratorPassword: String?,
        isAdministratorRetry: Bool = false
    ) async -> UpdateResult? {
        guard !isRunning, !packages.isEmpty else { return nil }
        if !isAdministratorRetry {
            lastAttemptedPackages = packages
        }
        administratorAccessRequired = false
        activity = .updating
        statusMessage = "Updating \(packages.count) package\(packages.count == 1 ? "" : "s")…"
        lastErrorMessage = nil
        progress = nil

        defer {
            activity = .idle
            progress = nil
        }

        do {
            let result = try await homebrewService.update(
                packages: packages,
                greedy: greedyModeEnabled,
                administratorPassword: administratorPassword,
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.progress = progress
                    }
                }
            )
            availablePackages = result.remainingPackages
            administratorAccessRequired = result.failures.contains { failure in
                if case .permissionRequired = HomebrewError.classified(
                    operation: failure.operation,
                    exitCode: failure.exitCode,
                    output: failure.output
                ) {
                    return true
                }
                return false
            }

            if !result.completedPackages.isEmpty {
                updateHistory = historyStore.append(
                    packages: result.completedPackages,
                    timestamp: result.timestamp
                )
            }

            if result.failures.isEmpty {
                var cleanupOutcome: UpdateCleanupOutcome?
                if autoCleanupEnabled, !result.completedPackages.isEmpty {
                    activity = .cleaning
                    statusMessage = "Cleaning up…"
                    do {
                        _ = try await homebrewService.cleanup(deep: false)
                        cleanupOutcome = .completed
                        statusMessage = "FreshBrew is ready"
                    } catch {
                        cleanupOutcome = .failed
                        await handleFailure(
                            error,
                            operation: "automatic cleanup",
                            status: "Cleanup failed"
                        )
                    }
                } else {
                    statusMessage = "FreshBrew is ready"
                }

                await notificationService.postUpdateCompletion(
                    updatedCount: result.completedPackages.count,
                    cleanupOutcome: cleanupOutcome
                )
            } else {
                let failureCount = result.failures.count
                statusMessage = "Update failed"
                lastErrorMessage = "\(failureCount) update operation\(failureCount == 1 ? "" : "s") failed"
                for failure in result.failures {
                    try? await errorLogStore.record(
                        operation: failure.operation,
                        output: failure.output,
                        timestamp: result.timestamp
                    )
                }
            }

            return result
        } catch {
            if let homebrewError = error as? HomebrewError,
               case .permissionRequired = homebrewError {
                administratorAccessRequired = true
            }
            await handleFailure(
                error,
                operation: "update packages",
                status: "Update failed"
            )
            return nil
        }
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
                _ = await self.checkUpdates(
                    respectMinimumInterval: false,
                    notifyIfAvailable: true
                )
            }
        }
    }

    private func cancelPendingUnlockCheck() {
        pendingUnlockCheckTask?.cancel()
        pendingUnlockCheckTask = nil
    }
}
