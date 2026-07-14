import Foundation
import XCTest
@testable import FreshBrew

@MainActor
final class MenuBarModelTests: XCTestCase {
    func testCheckAndUpdateStrictlyFollowGreedyMode() async throws {
        let package = makePackage(named: "firefox", kind: .cask)
        let service = FakeHomebrewService(
            checkResponses: [.packages([package]), .packages([package])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: package)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 200)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let firstCheckSucceeded = await model.checkUpdates()
        XCTAssertTrue(firstCheckSucceeded)
        model.greedyModeEnabled = true
        XCTAssertTrue(model.availablePackages.isEmpty)
        let secondCheckSucceeded = await model.checkUpdates()
        XCTAssertTrue(secondCheckSucceeded)
        _ = await model.updateAll()

        let checkModes = await service.recordedCheckGreedyValues()
        let updateModes = await service.recordedUpdateGreedyValues()
        XCTAssertEqual(checkModes, [false, true])
        XCTAssertEqual(updateModes, [true])
        XCTAssertEqual(model.checkUpdatesLabel, "Check Updates (Greedy)")
        XCTAssertEqual(model.updateAllLabel, "Update All (Greedy)")
    }

    func testChangingGreedyModeClearsStalePackagesAndSessionSkips() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [.packages([package])])
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        model.skip(package, remember: false)
        XCTAssertFalse(model.sessionSkippedPackageIDs.isEmpty)

        model.greedyModeEnabled = true

        XCTAssertTrue(model.availablePackages.isEmpty)
        XCTAssertTrue(model.sessionSkippedPackageIDs.isEmpty)
    }

    func testRememberedSkipPersistsAndFiltersVisiblePackages() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [.packages([package])])
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        model.skip(package, remember: true)

        XCTAssertTrue(model.visiblePackages.isEmpty)
        XCTAssertEqual(dependencies.preferences.rememberedSkippedPackageIDs, [package.id])
    }

    func testPartialUpdateAddsCompletedPackagesToHistoryAndKeepsFailuresVisible() async {
        let completed = makePackage(named: "completed", kind: .formula)
        let failed = makePackage(named: "failed", kind: .cask)
        let updateResult = UpdateResult(
            completedPackages: [makeUpdatedPackage(from: completed)],
            remainingPackages: [failed],
            failures: [HomebrewCommandFailure(
                operation: "upgrade casks",
                exitCode: 1,
                output: "cask failed"
            )],
            timestamp: Date(timeIntervalSince1970: 500)
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([completed, failed])],
            updateResult: updateResult
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        XCTAssertEqual(model.availablePackages, [failed])
        XCTAssertEqual(model.latestUpdate?.packages.map(\.name), ["completed"])
        XCTAssertNotNil(model.lastErrorMessage)
        let logEntries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(logEntries?.map(\.output), ["cask failed"])
    }

    func testFailedCheckKeepsPreviousPackagesAndWritesErrorLog() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [
            .packages([package]),
            .failure(.commandFailed(HomebrewCommandFailure(
                operation: "check",
                exitCode: 1,
                output: "network unavailable"
            )))
        ])
        let dependencies = makeDependencies(now: Date(timeIntervalSince1970: 1_000))
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let firstCheckSucceeded = await model.checkUpdates()
        let secondCheckSucceeded = await model.checkUpdates()
        XCTAssertTrue(firstCheckSucceeded)
        XCTAssertFalse(secondCheckSucceeded)

        XCTAssertEqual(model.availablePackages, [package])
        XCTAssertNotNil(model.lastErrorMessage)
        let entries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(entries?.first?.output, "network unavailable")
    }

    func testAutomaticCheckPostsOnlyNonzeroUpdateCount() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [
            .packages([]),
            .packages([package])
        ])
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates(notifyIfAvailable: true)
        _ = await model.checkUpdates(notifyIfAvailable: true)

        let updateCounts = await notifications.updateCounts()
        XCTAssertEqual(updateCounts, [1])
    }

    func testFailedCheckPostsFailureNotification() async {
        let service = FakeHomebrewService(checkResponses: [
            .failure(.commandFailed(HomebrewCommandFailure(
                operation: "check",
                exitCode: 1,
                output: "network unavailable"
            )))
        ])
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()

        let failureMessages = await notifications.failureMessages()
        XCTAssertEqual(failureMessages, ["Homebrew could not complete the operation."])
    }

    func testPermissionFailureCanRetrySamePackagesWithCurrentGreedyMode() async {
        let package = makePackage(named: "stats", kind: .cask)
        let completedResult = UpdateResult(
            completedPackages: [makeUpdatedPackage(from: package)],
            remainingPackages: [],
            failures: [],
            timestamp: Date(timeIntervalSince1970: 500)
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResponses: [
                .failure(.permissionRequired("sudo: a password is required")),
                .success(completedResult)
            ]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)
        model.greedyModeEnabled = true
        _ = await model.checkUpdates()

        _ = await model.updateAll()
        XCTAssertTrue(model.administratorAccessRequired)
        _ = await model.retryLastUpdate(administratorPassword: "secret")

        XCTAssertFalse(model.administratorAccessRequired)
        let updateModes = await service.recordedUpdateGreedyValues()
        let passwords = await service.recordedAdministratorPasswords()
        XCTAssertEqual(updateModes, [true, true])
        XCTAssertEqual(passwords, [nil, "secret"])
        XCTAssertTrue(model.availablePackages.isEmpty)
    }

    func testFailedManualCheckStillRecordsAttemptTimestamp() async {
        let referenceDate = Date(timeIntervalSince1970: 30_000)
        let service = FakeHomebrewService(checkResponses: [
            .failure(.commandFailed(HomebrewCommandFailure(
                operation: "check",
                exitCode: 1,
                output: "failed"
            )))
        ])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()

        XCTAssertEqual(dependencies.preferences.lastHomebrewCheckDate, referenceDate)
    }

    func testRecentCheckPreventsSchedulingUnlockDelay() async {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        dependencies.preferences.lastHomebrewCheckDate = referenceDate.addingTimeInterval(-100)
        let sleepRecorder = SleepRecorder()
        let model = makeModel(
            service: FakeHomebrewService(),
            dependencies: dependencies,
            sleep: { seconds in await sleepRecorder.record(seconds) }
        )

        model.startAutomaticChecks()
        model.scheduleCheckAfterUnlock(at: referenceDate)
        await Task.yield()

        XCTAssertFalse(model.hasPendingUnlockCheck)
        let recordedSleepValues = await sleepRecorder.recordedValues()
        XCTAssertEqual(recordedSleepValues, [])
    }

    func testEligibleUnlockWaitsOneMinuteThenChecksAgain() async {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let service = FakeHomebrewService(checkResponses: [.packages([])])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let sleepRecorder = SleepRecorder()
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            sleep: { seconds in await sleepRecorder.record(seconds) }
        )

        model.startAutomaticChecks()
        model.scheduleCheckAfterUnlock(at: referenceDate)
        await waitUntil { await service.checkCount() == 1 }

        let recordedSleepValues = await sleepRecorder.recordedValues()
        let checkCount = await service.checkCount()
        XCTAssertEqual(recordedSleepValues, [60])
        XCTAssertEqual(checkCount, 1)
    }

    func testSecondIntervalGateSkipsCheckWhenAnotherAttemptOccursDuringDelay() async {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let service = FakeHomebrewService()
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let preferences = dependencies.preferences
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            sleep: { _ in preferences.lastHomebrewCheckDate = referenceDate }
        )

        model.startAutomaticChecks()
        model.scheduleCheckAfterUnlock(at: referenceDate)
        await waitUntil { !model.hasPendingUnlockCheck }

        let checkCount = await service.checkCount()
        XCTAssertEqual(checkCount, 0)
        XCTAssertFalse(model.hasPendingUnlockCheck)
    }

    func testDuplicateUnlockCancelsFirstPendingDelay() async {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let service = FakeHomebrewService(checkResponses: [.packages([])])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let controller = ControlledSleeper()
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            sleep: { seconds in try await controller.sleep(seconds) }
        )

        model.startAutomaticChecks()
        model.scheduleCheckAfterUnlock(at: referenceDate)
        await waitUntil { await controller.totalCallCount() == 1 }
        model.scheduleCheckAfterUnlock(at: referenceDate)
        await waitUntil { await controller.totalCallCount() == 2 }

        await controller.resumeAll()
        await waitUntil { await service.checkCount() == 1 }

        let checkCount = await service.checkCount()
        let cancelledCallCount = await controller.cancelledCallCount()
        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(cancelledCallCount, 1)
    }

    func testPeriodicModeChecksAtConfiguredIntervalAndCancelsWhenModeChanges() async {
        let referenceDate = Date(timeIntervalSince1970: 40_000)
        let service = FakeHomebrewService(checkResponses: [.packages([])])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        dependencies.preferences.periodicCheckInterval = 7_200
        let controller = ControlledSleeper()
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            sleep: { seconds in try await controller.sleep(seconds) }
        )
        model.automaticCheckMode = .periodic

        model.startAutomaticChecks()
        await waitUntil { await controller.totalCallCount() == 1 }
        await controller.resumeAll()
        await waitUntil { await service.checkCount() == 1 }
        await waitUntil { await controller.totalCallCount() == 2 }
        model.automaticCheckMode = .afterUnlock
        await waitUntil { await controller.cancelledCallCount() >= 1 }

        let intervals = await controller.recordedIntervals()
        let checkCount = await service.checkCount()
        XCTAssertEqual(intervals, [7_200, 7_200])
        XCTAssertEqual(checkCount, 1)
    }

    private func makeModel(
        service: FakeHomebrewService,
        dependencies: ModelDependencies,
        notificationService: any NotificationServing = NoopNotificationService(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> MenuBarModel {
        let referenceDate = dependencies.referenceDate
        return MenuBarModel(
            homebrewService: service,
            preferences: dependencies.preferences,
            historyStore: dependencies.historyStore,
            errorLogStore: dependencies.errorLogStore,
            notificationService: notificationService,
            launchAtLoginService: FakeLaunchAtLoginService(),
            now: { referenceDate },
            sleep: sleep
        )
    }

    private func makeDependencies(now: Date = Date(timeIntervalSince1970: 10_000)) -> ModelDependencies {
        let suiteName = "net.siann.freshbrew.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ModelDependencies(
            suiteName: suiteName,
            defaults: defaults,
            preferences: FreshBrewPreferences(defaults: defaults),
            historyStore: UpdateHistoryStore(defaults: defaults),
            errorLogStore: HomebrewErrorLogStore(
                fileURL: logDirectory.appendingPathComponent("homebrew-errors.json")
            ),
            logDirectory: logDirectory,
            referenceDate: now
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met")
    }

    private func makePackage(
        named name: String,
        kind: HomebrewPackageKind
    ) -> HomebrewPackage {
        HomebrewPackage(
            name: name,
            installedVersion: "1.0",
            availableVersion: "2.0",
            kind: kind
        )
    }

    private func makeUpdatedPackage(from package: HomebrewPackage) -> UpdatedPackage {
        UpdatedPackage(
            name: package.name,
            previousVersion: package.installedVersion,
            installedVersion: package.availableVersion,
            kind: package.kind
        )
    }
}

private struct ModelDependencies {
    let suiteName: String
    let defaults: UserDefaults
    let preferences: FreshBrewPreferences
    let historyStore: UpdateHistoryStore
    let errorLogStore: HomebrewErrorLogStore
    let logDirectory: URL
    let referenceDate: Date

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: logDirectory)
    }
}

private actor FakeHomebrewService: HomebrewServicing {
    enum CheckResponse: Sendable {
        case packages([HomebrewPackage])
        case failure(HomebrewError)
    }

    private var checkResponses: [CheckResponse]
    private var updateResponses: [Result<UpdateResult, HomebrewError>]
    private var checkGreedyValues: [Bool] = []
    private var updateGreedyValues: [Bool] = []
    private var administratorPasswords: [String?] = []

    init(
        checkResponses: [CheckResponse] = [],
        updateResult: UpdateResult? = nil,
        updateResponses: [Result<UpdateResult, HomebrewError>] = []
    ) {
        self.checkResponses = checkResponses
        if let updateResult {
            self.updateResponses = [.success(updateResult)]
        } else {
            self.updateResponses = updateResponses
        }
    }

    func checkOutdated(
        greedy: Bool,
        refreshMetadata: Bool
    ) async throws -> [HomebrewPackage] {
        checkGreedyValues.append(greedy)
        guard !checkResponses.isEmpty else { return [] }
        switch checkResponses.removeFirst() {
        case let .packages(packages):
            return packages
        case let .failure(error):
            throw error
        }
    }

    func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        administratorPassword: String?,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult {
        updateGreedyValues.append(greedy)
        administratorPasswords.append(administratorPassword)
        if !updateResponses.isEmpty {
            return try updateResponses.removeFirst().get()
        }
        return UpdateResult(
            completedPackages: [],
            remainingPackages: packages,
            failures: [],
            timestamp: Date()
        )
    }

    func cleanup(deep: Bool) async throws -> CleanupResult {
        CleanupResult(isDeepCleanup: deep, output: "", completedAt: Date())
    }

    func recordedCheckGreedyValues() -> [Bool] {
        checkGreedyValues
    }

    func recordedUpdateGreedyValues() -> [Bool] {
        updateGreedyValues
    }

    func recordedAdministratorPasswords() -> [String?] {
        administratorPasswords
    }

    func checkCount() -> Int {
        checkGreedyValues.count
    }
}

private actor FakeNotificationService: NotificationServing {
    private var counts: [Int] = []
    private var failures: [String] = []

    func requestAuthorization() async {}

    func postUpdatesAvailable(count: Int) async {
        guard count > 0 else { return }
        counts.append(count)
    }

    func postCheckFailure(message: String) async {
        failures.append(message)
    }

    func updateCounts() -> [Int] { counts }
    func failureMessages() -> [String] { failures }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}

private actor SleepRecorder {
    private var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }

    func recordedValues() -> [TimeInterval] {
        values
    }
}

private actor ControlledSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelledIDs = Set<UUID>()
    private var calls = 0
    private var cancellations = 0
    private var intervals: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        calls += 1
        intervals.append(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeAll() {
        let currentWaiters = waiters.values
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }

    func totalCallCount() -> Int {
        calls
    }

    func cancelledCallCount() -> Int {
        cancellations
    }

    func recordedIntervals() -> [TimeInterval] {
        intervals
    }

    private func cancel(_ id: UUID) {
        cancellations += 1
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }
}
