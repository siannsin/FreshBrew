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
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var sessionSkippedPackageIDs = Set<String>()
    @Published private(set) var rememberedSkippedPackageIDs: Set<String>

    @Published var greedyModeEnabled: Bool {
        didSet {
            guard greedyModeEnabled != oldValue else { return }
            preferences.greedyModeEnabled = greedyModeEnabled
            availablePackages = []
            sessionSkippedPackageIDs = []
            statusMessage = "Check updates for the selected Greedy Mode"
        }
    }

    @Published var automaticCheckMode: AutomaticCheckMode {
        didSet {
            guard automaticCheckMode != oldValue else { return }
            preferences.automaticCheckMode = automaticCheckMode
            configureAutomaticChecksIfStarted()
        }
    }

    @Published var autoCleanupEnabled: Bool {
        didSet { preferences.autoCleanupEnabled = autoCleanupEnabled }
    }

    @Published var launchAtLoginEnabled: Bool {
        didSet { preferences.launchAtLoginEnabled = launchAtLoginEnabled }
    }

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
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var automaticChecksStarted = false
    private var pendingUnlockCheckTask: Task<Void, Never>?
    private var periodicCheckTask: Task<Void, Never>?

    init(
        homebrewService: any HomebrewServicing = HomebrewService(),
        preferences: FreshBrewPreferences = FreshBrewPreferences(),
        historyStore: UpdateHistoryStore = UpdateHistoryStore(),
        errorLogStore: HomebrewErrorLogStore = HomebrewErrorLogStore(),
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
        self.now = now
        self.sleep = sleep
        greedyModeEnabled = preferences.greedyModeEnabled
        automaticCheckMode = preferences.automaticCheckMode
        autoCleanupEnabled = preferences.autoCleanupEnabled
        launchAtLoginEnabled = preferences.launchAtLoginEnabled
        rememberedSkippedPackageIDs = preferences.rememberedSkippedPackageIDs
        updateHistory = historyStore.load()
    }

    func checkUpdates(respectMinimumInterval: Bool = false) async -> Bool {
        guard !isRunning else { return false }
        if respectMinimumInterval, !shouldRunHomebrewCheck() {
            return false
        }

        activity = .checking
        progress = nil
        statusMessage = "Checking Homebrew updates…"
        lastErrorMessage = nil
        preferences.lastHomebrewCheckDate = now()

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
            statusMessage = packages.isEmpty
                ? "Homebrew is up to date"
                : "\(packages.count) update\(packages.count == 1 ? "" : "s") available"
            return true
        } catch {
            await handleFailure(error, operation: "check updates")
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

    func cleanup(deep: Bool) async -> CleanupResult? {
        guard !isRunning else { return nil }
        activity = .cleaning
        statusMessage = deep ? "Running deep cleanup…" : "Running cleanup…"
        lastErrorMessage = nil
        defer { activity = .idle }

        do {
            let result = try await homebrewService.cleanup(deep: deep)
            statusMessage = deep ? "Deep cleanup completed" : "Cleanup completed"
            return result
        } catch {
            await handleFailure(error, operation: deep ? "deep cleanup" : "cleanup")
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
            _ = await self.checkUpdates(respectMinimumInterval: true)
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
        administratorPassword: String?
    ) async -> UpdateResult? {
        guard !isRunning, !packages.isEmpty else { return nil }
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
                        self?.statusMessage = progress.message
                    }
                }
            )
            availablePackages = result.remainingPackages

            if !result.completedPackages.isEmpty {
                updateHistory = historyStore.append(
                    packages: result.completedPackages,
                    timestamp: result.timestamp
                )
            }

            if result.failures.isEmpty {
                statusMessage = "Updated \(result.completedCount) package\(result.completedCount == 1 ? "" : "s")"
            } else {
                let failureCount = result.failures.count
                statusMessage = "Some Homebrew updates did not complete"
                lastErrorMessage = "\(failureCount) update operation\(failureCount == 1 ? "" : "s") failed"
                for failure in result.failures {
                    try? await errorLogStore.record(
                        operation: failure.operation,
                        output: failure.output,
                        timestamp: result.timestamp
                    )
                }
            }

            if autoCleanupEnabled, !result.completedPackages.isEmpty {
                do {
                    _ = try await homebrewService.cleanup(deep: false)
                } catch {
                    await handleFailure(error, operation: "automatic cleanup")
                }
            }

            return result
        } catch {
            await handleFailure(error, operation: "update packages")
            return nil
        }
    }

    private func handleFailure(_ error: Error, operation: String) async {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let output = Self.diagnosticOutput(for: error)
        lastErrorMessage = message
        statusMessage = "Homebrew operation failed"
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
        let interval = max(60, preferences.periodicCheckInterval)
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
                _ = await self.checkUpdates(respectMinimumInterval: true)
            }
        }
    }

    private func cancelPendingUnlockCheck() {
        pendingUnlockCheckTask?.cancel()
        pendingUnlockCheckTask = nil
    }
}
