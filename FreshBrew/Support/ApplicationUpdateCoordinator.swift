import AppKit
import Combine
import Foundation

@MainActor
final class ApplicationUpdateCoordinator: ObservableObject {
    enum ManualState: Equatable {
        case idle
        case checking
        case current
        case updateAvailable(ApplicationRelease)
        case failed(String)
    }

    static let backgroundCheckInterval: TimeInterval = 86_400
    static let failedCheckRetryInterval: TimeInterval = 3_600

    @Published private(set) var manualState: ManualState = .idle
    @Published var checksEnabled: Bool {
        didSet {
            guard checksEnabled != oldValue else { return }
            preferences.appUpdateChecksEnabled = checksEnabled
            configureBackgroundChecksIfStarted()
        }
    }

    private let checker: any ApplicationUpdateChecking
    private let preferences: FreshBrewPreferences
    private let notificationService: any ApplicationUpdateNotificationServing
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let openURL: (URL) -> Bool

    private var checksStarted = false
    private var activeCheckTask: Task<ApplicationUpdateCheckResult, Error>?
    private var backgroundTask: Task<Void, Never>?
    private var lastBackgroundCheckFailed = false

    init(
        checker: any ApplicationUpdateChecking,
        preferences: FreshBrewPreferences,
        notificationService: any ApplicationUpdateNotificationServing,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.checker = checker
        self.preferences = preferences
        self.notificationService = notificationService
        self.now = now
        self.sleep = sleep
        self.openURL = openURL
        checksEnabled = preferences.appUpdateChecksEnabled
    }

    var isChecking: Bool {
        manualState == .checking
    }

    func checkManually() async {
        manualState = .checking

        do {
            let result = try await performCheck()
            lastBackgroundCheckFailed = false
            preferences.lastSuccessfulAppUpdateCheckDate = now()
            switch result {
            case .current:
                manualState = .current
            case let .updateAvailable(release):
                manualState = .updateAvailable(release)
            }
        } catch {
            manualState = .failed(Self.failureMessage(for: error))
        }
    }

    @discardableResult
    func checkInBackgroundIfNeeded(at date: Date? = nil) async -> Bool {
        let checkDate = date ?? now()
        guard checksEnabled,
              shouldRunBackgroundCheck(at: checkDate) else {
            return false
        }

        do {
            let result = try await performCheck()
            guard checksEnabled else { return true }
            lastBackgroundCheckFailed = false
            preferences.lastSuccessfulAppUpdateCheckDate = checkDate
            guard case let .updateAvailable(release) = result,
                  preferences.lastNotifiedAppVersion != release.displayVersion else {
                return true
            }

            preferences.lastNotifiedAppVersion = release.displayVersion
            await notificationService.postApplicationUpdateAvailable(
                version: release.displayVersion,
                releasePageURL: release.pageURL
            )
            return true
        } catch {
            lastBackgroundCheckFailed = true
            return true
        }
    }

    func startBackgroundChecks() {
        guard !checksStarted else { return }
        checksStarted = true
        configureBackgroundChecksIfStarted()
    }

    func stopBackgroundChecks() {
        checksStarted = false
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    @discardableResult
    func openAvailableRelease() -> Bool {
        guard case let .updateAvailable(release) = manualState else { return false }
        return openReleasePage(release.pageURL)
    }

    @discardableResult
    func openReleasePage(from value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return openReleasePage(url)
    }

    func shouldRunBackgroundCheck(at date: Date? = nil) -> Bool {
        guard let lastCheckDate = preferences.lastSuccessfulAppUpdateCheckDate else {
            return true
        }
        return (date ?? now()).timeIntervalSince(lastCheckDate)
            >= Self.backgroundCheckInterval
    }

    private func openReleasePage(_ url: URL) -> Bool {
        guard GitHubApplicationUpdateService.isValidReleasePageURL(url) else {
            return false
        }
        return openURL(url)
    }

    private func performCheck() async throws -> ApplicationUpdateCheckResult {
        if let activeCheckTask {
            return try await activeCheckTask.value
        }

        let checker = self.checker
        let task = Task { try await checker.check() }
        activeCheckTask = task
        defer { activeCheckTask = nil }
        return try await task.value
    }

    private func configureBackgroundChecksIfStarted() {
        guard checksStarted else { return }
        backgroundTask?.cancel()
        backgroundTask = nil
        guard checksEnabled else { return }

        let sleep = self.sleep
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.checkInBackgroundIfNeeded()
                let delay = self.nextBackgroundDelay()
                do {
                    try await sleep(delay)
                    try Task.checkCancellation()
                } catch {
                    return
                }
            }
        }
    }

    func nextBackgroundDelay() -> TimeInterval {
        if lastBackgroundCheckFailed {
            return Self.failedCheckRetryInterval
        }
        guard let lastCheckDate = preferences.lastSuccessfulAppUpdateCheckDate else {
            return Self.failedCheckRetryInterval
        }
        let elapsed = now().timeIntervalSince(lastCheckDate)
        return max(60, Self.backgroundCheckInterval - elapsed)
    }

    private static func failureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "Could not connect to GitHub."
            default:
                break
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? "The update check could not be completed."
    }
}
