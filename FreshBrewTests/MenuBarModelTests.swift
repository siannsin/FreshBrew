import Foundation
import XCTest
@testable import FreshBrew

@MainActor
final class MenuBarModelTests: XCTestCase {
    func testLoadingInstalledPackagesStoresInventoryAndLoadedState() async {
        let inventory = [
            InstalledPackage(
                name: "ripgrep",
                installedVersion: "14.1.1",
                kind: .formula
            ),
            InstalledPackage(
                name: "chatgpt",
                installedVersion: "1.2026.231",
                kind: .cask
            )
        ]
        let service = FakeHomebrewService(
            installedPackageResponses: [.success(inventory)]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let succeeded = await model.loadInstalledPackages()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.installedPackages, inventory)
        XCTAssertEqual(model.installedPackagesLoadState, .loaded)
    }

    func testLoadingEmptyInstalledPackageInventoryFinishesLoaded() async {
        let service = FakeHomebrewService(
            installedPackageResponses: [.success([])]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let succeeded = await model.loadInstalledPackages()

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.installedPackages.isEmpty)
        XCTAssertEqual(model.installedPackagesLoadState, .loaded)
    }

    func testInitialInstalledPackageLoadFailurePublishesFailureState() async {
        let failure = HomebrewError.commandFailed(HomebrewCommandFailure(
            operation: "read installed packages",
            exitCode: 1,
            output: "metadata unavailable"
        ))
        let service = FakeHomebrewService(installedPackageResponses: [
            .failure(failure)
        ])
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let succeeded = await model.loadInstalledPackages()

        XCTAssertFalse(succeeded)
        XCTAssertTrue(model.installedPackages.isEmpty)
        XCTAssertEqual(
            model.installedPackagesLoadState,
            .failed(failure.localizedDescription)
        )
    }

    func testFailedInstalledPackageRefreshPreservesPreviousInventory() async {
        let inventory = [
            InstalledPackage(
                name: "ripgrep",
                installedVersion: "14.1.1",
                kind: .formula
            )
        ]
        let service = FakeHomebrewService(installedPackageResponses: [
            .success(inventory),
            .failure(.timedOut(
                operation: "read installed packages",
                seconds: 30,
                output: "metadata stalled"
            ))
        ])
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let initialLoadSucceeded = await model.loadInstalledPackages()
        let refreshSucceeded = await model.loadInstalledPackages()

        XCTAssertTrue(initialLoadSucceeded)
        XCTAssertFalse(refreshSucceeded)
        XCTAssertEqual(model.installedPackages, inventory)
        XCTAssertEqual(
            model.installedPackagesLoadState,
            .failed("Read Installed Packages timed out after 30 seconds.")
        )
    }

    func testCompletedUpdateMarksInstalledInventoryStaleUntilReloaded() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let originalInventory = InstalledPackage(
            name: package.name,
            installedVersion: package.installedVersion,
            kind: package.kind
        )
        let refreshedInventory = InstalledPackage(
            name: package.name,
            installedVersion: package.availableVersion,
            kind: package.kind
        )
        let service = FakeHomebrewService(
            installedPackageResponses: [
                .success([originalInventory]),
                .success([refreshedInventory])
            ],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: package)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let initialLoadSucceeded = await model.loadInstalledPackages()
        XCTAssertTrue(initialLoadSucceeded)
        XCTAssertFalse(model.installedPackagesNeedRefresh)

        _ = await model.update(package: package)

        XCTAssertTrue(model.installedPackagesNeedRefresh)
        XCTAssertEqual(model.installedPackages, [originalInventory])

        let refreshedLoadSucceeded = await model.loadInstalledPackages()
        XCTAssertTrue(refreshedLoadSucceeded)
        XCTAssertFalse(model.installedPackagesNeedRefresh)
        XCTAssertEqual(model.installedPackages, [refreshedInventory])
    }

    func testInstalledInventoryLoadPreventsConcurrentHomebrewCheck() async {
        let gate = ControlledSleeper()
        let service = FakeHomebrewService(
            installedPackageResponses: [.success([])],
            installedPackagesGate: gate
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let loadTask = Task { await model.loadInstalledPackages() }
        await waitUntil { await gate.totalCallCount() == 1 }

        XCTAssertTrue(model.isRunning)
        let checkSucceeded = await model.checkUpdates()
        let checkCount = await service.checkCount()
        XCTAssertFalse(checkSucceeded)
        XCTAssertEqual(checkCount, 0)

        await gate.resumeAll()
        let loadSucceeded = await loadTask.value
        XCTAssertTrue(loadSucceeded)
        XCTAssertFalse(model.isRunning)
    }

    func testRememberingInstalledPackageSkipPersistsAndFiltersAvailablePackage() async {
        let homepageURL = URL(string: "https://formulae.brew.sh/formula/ripgrep")
        let availablePackage = HomebrewPackage(
            name: "ripgrep",
            installedVersion: "14.1.0",
            availableVersion: "14.1.1",
            kind: .formula
        )
        let installedPackage = InstalledPackage(
            name: "ripgrep",
            installedVersion: "14.1.0",
            kind: .formula,
            homepageURL: homepageURL
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([availablePackage])]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        model.rememberSkip(installedPackage)

        XCTAssertTrue(model.visiblePackages.isEmpty)
        XCTAssertTrue(model.sessionSkippedPackageIDs.contains(installedPackage.id))
        XCTAssertTrue(model.rememberedSkippedPackageIDs.contains(installedPackage.id))
        XCTAssertEqual(
            dependencies.preferences.rememberedSkippedPackageIDs,
            [installedPackage.id]
        )
        XCTAssertEqual(
            model.cachedPackageHomepageURL(for: installedPackage.id),
            homepageURL
        )
    }

    func testStoppingInstalledPackageSkipClearsRememberedAndSessionState() {
        let package = InstalledPackage(
            name: "chatgpt",
            installedVersion: "1.2026.231",
            kind: .cask
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: FakeHomebrewService(),
            dependencies: dependencies
        )

        model.rememberSkip(package)

        XCTAssertTrue(model.sessionSkippedPackageIDs.contains(package.id))
        XCTAssertTrue(model.rememberedSkippedPackageIDs.contains(package.id))
        XCTAssertEqual(
            dependencies.preferences.rememberedSkippedPackageIDs,
            [package.id]
        )

        model.forgetSkippedPackage(id: package.id)

        XCTAssertFalse(model.sessionSkippedPackageIDs.contains(package.id))
        XCTAssertFalse(model.rememberedSkippedPackageIDs.contains(package.id))
        XCTAssertTrue(dependencies.preferences.rememberedSkippedPackageIDs.isEmpty)
    }

    func testPackageHomepageOpenFailureProducesVisibleStatus() {
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: FakeHomebrewService(),
            dependencies: dependencies
        )

        model.reportPackageHomepageOpenFailure()

        XCTAssertEqual(model.packageHomepageErrorMessage, "Could not open package homepage")
        XCTAssertNil(model.lastErrorMessage)

        model.reportPackageHomepageOpened()

        XCTAssertNil(model.packageHomepageErrorMessage)
    }

    func testCheckEnrichesPackagesAndPersistsHomepageIntoHistory() async throws {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let homepageURL = try XCTUnwrap(
            URL(string: "https://github.com/BurntSushi/ripgrep")
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: package)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 200)
            ),
            homepageURLs: [package.id: homepageURL]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        XCTAssertEqual(model.availablePackages.first?.homepageURL, homepageURL)
        _ = await model.updateAll()

        XCTAssertEqual(model.latestUpdate?.packages.first?.homepageURL, homepageURL)
        XCTAssertEqual(
            UpdateHistoryStore(defaults: dependencies.defaults)
                .load().first?.packages.first?.homepageURL,
            homepageURL
        )
    }

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

    func testManualCleanupPostsSuccessfulResultNotification() async {
        let cleanupResult = CleanupResult(
            isDeepCleanup: false,
            output: "This operation has freed approximately 42MB of disk space.",
            completedAt: Date(timeIntervalSince1970: 500)
        )
        let service = FakeHomebrewService(
            cleanupResponses: [.success(cleanupResult)]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        let result = await model.cleanup(deep: false)

        let cleanupDeepValues = await service.recordedCleanupDeepValues()
        let cleanupResults = await notifications.cleanupResults()
        let cleanupFailures = await notifications.cleanupFailures()
        XCTAssertEqual(result, cleanupResult)
        XCTAssertEqual(cleanupDeepValues, [false])
        XCTAssertEqual(cleanupResults, [cleanupResult])
        XCTAssertTrue(cleanupFailures.isEmpty)
        XCTAssertEqual(model.statusMessage, "FreshBrew is ready")
        XCTAssertEqual(model.activity, .idle)
    }

    func testManualDeepCleanupWithoutFreedSpaceStaysSilent() async {
        let cleanupResult = CleanupResult(
            isDeepCleanup: true,
            output: "Pruned 0 symbolic links and 2 directories.",
            completedAt: Date(timeIntervalSince1970: 500)
        )
        let service = FakeHomebrewService(
            cleanupResponses: [.success(cleanupResult)]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        let result = await model.cleanup(deep: true)

        let cleanupDeepValues = await service.recordedCleanupDeepValues()
        let cleanupResults = await notifications.cleanupResults()
        let cleanupFailures = await notifications.cleanupFailures()
        XCTAssertEqual(result, cleanupResult)
        XCTAssertEqual(cleanupDeepValues, [true])
        XCTAssertTrue(cleanupResults.isEmpty)
        XCTAssertTrue(cleanupFailures.isEmpty)
        XCTAssertEqual(model.activity, .idle)
    }

    func testManualCleanupTimeoutPostsFailureNotificationAndKeepsDiagnosticLog() async {
        let failure = HomebrewError.timedOut(
            operation: "cleanup",
            seconds: 300,
            output: "cleanup command timed out"
        )
        let service = FakeHomebrewService(
            cleanupResponses: [.failure(failure)]
        )
        let notifications = FakeNotificationService()
        let referenceDate = Date(timeIntervalSince1970: 500)
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        let result = await model.cleanup(deep: false)

        XCTAssertNil(result)
        let failures = await notifications.cleanupFailures()
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(failures[0].deep)
        XCTAssertEqual(failures[0].message, "Cleanup timed out after 5 minutes.")
        XCTAssertEqual(model.statusMessage, "Cleanup timed out")
        let entries = try? await dependencies.errorLogStore.entries(referenceDate: referenceDate)
        XCTAssertEqual(entries?.first?.operation, "cleanup")
        XCTAssertEqual(
            entries?.first?.output,
            "cleanup command timed out\nFreshBrew stopped cleanup after 300 seconds."
        )
        XCTAssertEqual(model.activity, .idle)
    }

    func testManualDeepCleanupNetworkFailurePostsFailureNotification() async {
        let service = FakeHomebrewService(
            cleanupResponses: [.failure(.networkUnavailable)]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        let result = await model.cleanup(deep: true)

        XCTAssertNil(result)
        let failures = await notifications.cleanupFailures()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].deep)
        XCTAssertEqual(
            failures[0].message,
            "Network unavailable. Check your connection and try again."
        )
        XCTAssertEqual(model.activity, .idle)
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
        XCTAssertNotNil(model.lastSuccessfulHomebrewCheckDate)

        model.greedyModeEnabled = true

        XCTAssertTrue(model.availablePackages.isEmpty)
        XCTAssertTrue(model.sessionSkippedPackageIDs.isEmpty)
        XCTAssertNil(model.lastSuccessfulHomebrewCheckDate)
        XCTAssertNil(dependencies.preferences.lastSuccessfulHomebrewCheckDate)
        XCTAssertTrue(model.shouldRunHomebrewCheck())
        XCTAssertEqual(model.statusMessage, "FreshBrew is ready")
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

    func testForgettingRememberedSkipClearsItsSessionSkipAndRestoresPackage() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [.packages([package])])
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        model.skip(package, remember: true)
        model.forgetSkippedPackage(id: package.id)

        XCTAssertEqual(model.visiblePackages, [package])
        XCTAssertFalse(model.sessionSkippedPackageIDs.contains(package.id))
        XCTAssertFalse(model.rememberedSkippedPackageIDs.contains(package.id))
        XCTAssertTrue(dependencies.preferences.rememberedSkippedPackageIDs.isEmpty)
    }

    func testForgettingUnknownRememberedSkipPreservesSessionOnlySkip() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [.packages([package])])
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        model.skip(package, remember: false)
        model.forgetSkippedPackage(id: package.id)

        XCTAssertTrue(model.visiblePackages.isEmpty)
        XCTAssertTrue(model.sessionSkippedPackageIDs.contains(package.id))
        XCTAssertTrue(model.rememberedSkippedPackageIDs.isEmpty)
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
        XCTAssertEqual(model.statusMessage, "Update failed")
        let logEntries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(logEntries?.map(\.output), ["cask failed"])
    }

    func testSuccessfulUpdateRunsAutomaticCleanupAndPostsCombinedNotification() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: package)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 500)
            ),
            cleanupResponses: [.success(CleanupResult(
                isDeepCleanup: false,
                output: "This operation has freed approximately 42MB of disk space.",
                completedAt: Date(timeIntervalSince1970: 500)
            ))]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.update(package: package)

        let cleanupDeepValues = await service.recordedCleanupDeepValues()
        let completionValues = await notifications.completions()
        XCTAssertEqual(cleanupDeepValues, [false])
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 0,
                hadFailures: false,
                newlyAvailableCount: 0,
                cleanupOutcome: .completed(freedSpace: "42MB")
            )]
        )
        XCTAssertEqual(model.statusMessage, "FreshBrew is ready")
    }

    func testSuccessfulUpdateReportsOnlyNewlyDiscoveredPackages() async {
        let selectedPackage = makePackage(named: "ripgrep", kind: .formula)
        let alreadyKnownPackage = makePackage(named: "stats", kind: .cask)
        let newlyAvailablePackage = makePackage(named: "wget", kind: .formula)
        let service = FakeHomebrewService(
            checkResponses: [.packages([selectedPackage, alreadyKnownPackage])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: selectedPackage)],
                remainingPackages: [alreadyKnownPackage, newlyAvailablePackage],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()
        _ = await model.update(package: selectedPackage)

        let completionValues = await notifications.completions()
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 2,
                hadFailures: false,
                newlyAvailableCount: 1,
                cleanupOutcome: nil
            )]
        )
    }

    func testAutomaticCleanupFailureIsReportedWithSuccessfulUpdate() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let cleanupFailure = HomebrewError.commandFailed(HomebrewCommandFailure(
            operation: "cleanup",
            exitCode: 1,
            output: "cleanup failed"
        ))
        let service = FakeHomebrewService(
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: package)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 500)
            ),
            cleanupResponses: [.failure(cleanupFailure)]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies(now: Date(timeIntervalSince1970: 500))
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.update(package: package)

        let completionValues = await notifications.completions()
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 0,
                hadFailures: false,
                newlyAvailableCount: 0,
                cleanupOutcome: .failed
            )]
        )
        XCTAssertEqual(model.statusMessage, "Cleanup failed")
        XCTAssertNotNil(model.lastErrorMessage)
        let entries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(entries?.first?.operation, "automatic cleanup")
    }

    func testPartialUpdateSkipsAutomaticCleanupAndPostsResult() async {
        let completed = makePackage(named: "ripgrep", kind: .formula)
        let remaining = makePackage(named: "stats", kind: .cask)
        let service = FakeHomebrewService(
            checkResponses: [.packages([completed, remaining])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: completed)],
                remainingPackages: [remaining],
                failures: [HomebrewCommandFailure(
                    operation: "upgrade casks",
                    exitCode: 1,
                    output: "cask failed"
                )],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        let cleanupDeepValues = await service.recordedCleanupDeepValues()
        let completionValues = await notifications.completions()
        XCTAssertTrue(cleanupDeepValues.isEmpty)
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 1,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
        XCTAssertEqual(model.statusMessage, "Update failed")
    }

    func testUnavailableVerificationPreservesStateAndHistory() async {
        let completed = makePackage(named: "ripgrep", kind: .formula)
        let uncertain = makePackage(named: "spotify", kind: .cask)
        let verificationFailure = HomebrewCommandFailure(
            operation: "verify updates",
            exitCode: -1,
            output: "verification timed out",
            kind: .timeout
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([completed, uncertain])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: completed)],
                remainingPackages: [uncertain],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 500),
                verification: .unavailable(verificationFailure)
            )
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies(now: Date(timeIntervalSince1970: 500))
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        XCTAssertEqual(model.availablePackages, [completed, uncertain])
        XCTAssertEqual(model.latestUpdate?.packages.map(\.name), ["ripgrep"])
        XCTAssertEqual(model.statusMessage, "Verification failed")
        XCTAssertEqual(
            model.lastErrorMessage,
            "FreshBrew could not verify the remaining updates."
        )
        let cleanupDeepValues = await service.recordedCleanupDeepValues()
        let completionValues = await notifications.completions()
        XCTAssertTrue(cleanupDeepValues.isEmpty)
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 2,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil,
                verificationUnavailable: true
            )]
        )
        let logEntries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(logEntries?.first?.operation, "verify updates")
        XCTAssertEqual(logEntries?.first?.output, "verification timed out")
    }

    func testPermissionFailureFinalizesPartialSuccessInOneBatch() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let cask = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: authentication failed"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, cask])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: formula)],
                remainingPackages: [cask],
                failures: [permissionFailure],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        let updateBatches = await service.recordedUpdatePackageIDBatches()
        XCTAssertEqual(updateBatches, [[formula.id, cask.id]])
        XCTAssertEqual(model.latestUpdate?.packages.map(\.name), ["ripgrep"])
        XCTAssertEqual(model.availablePackages.map(\.id), [cask.id])
        let completions = await notifications.completions()
        XCTAssertEqual(
            completions,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 1,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
    }

    func testPermissionCancellationWithoutSuccessPostsFailureNotification() async {
        let package = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: no password was provided"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResult: UpdateResult(
                completedPackages: [],
                remainingPackages: [package],
                failures: [permissionFailure],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        let completions = await notifications.completions()
        XCTAssertEqual(
            completions,
            [UpdateCompletion(
                updatedCount: 0,
                remainingUpdateCount: 1,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
        XCTAssertTrue(model.updateHistory.isEmpty)
    }
    func testThrownUpdateFailurePostsFinalFailureNotification() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResponses: [.failure(.networkUnavailable)]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        let completionValues = await notifications.completions()
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 0,
                remainingUpdateCount: 1,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
    }

    func testTimedOutUpdateUsesSpecificStatusAndWritesDiagnosticLog() async {
        let package = makePackage(named: "large-cask", kind: .cask)
        let service = FakeHomebrewService(
            updateResult: UpdateResult(
                completedPackages: [],
                remainingPackages: [package],
                failures: [HomebrewCommandFailure(
                    operation: "upgrade casks",
                    exitCode: -1,
                    output: "download stalled",
                    kind: .timeout
                )],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let dependencies = makeDependencies(now: Date(timeIntervalSince1970: 500))
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.update(package: package)

        XCTAssertEqual(model.statusMessage, "Update timed out")
        XCTAssertEqual(model.lastErrorMessage, "A package update exceeded its time limit.")
        let entries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(entries?.first?.output, "download stalled")
    }

    func testFailedCheckKeepsPreviousPackagesAndWritesErrorLog() async {
        let package = makePackage(named: "ripgrep", kind: .formula)
        let diagnosticOutput = """
        ==> Updating Homebrew...
        fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve host: github.com
        Error: Fetching /opt/homebrew failed!
        """
        let service = FakeHomebrewService(checkResponses: [
            .packages([package]),
            .failure(.commandFailed(HomebrewCommandFailure(
                operation: "check",
                exitCode: 1,
                output: diagnosticOutput
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
        XCTAssertEqual(
            model.lastErrorMessage,
            "Network unavailable. Check your connection and try again."
        )
        XCTAssertEqual(model.statusMessage, "Network unavailable")
        let entries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(entries?.first?.output, diagnosticOutput)
    }

    func testCheckPostsOnlyNonzeroUpdateCount() async {
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

        _ = await model.checkUpdates()
        _ = await model.checkUpdates()

        let updateCounts = await notifications.updateCounts()
        XCTAssertEqual(updateCounts, [1])
    }

    func testCheckNotificationExcludesRememberedSkippedPackages() async {
        let skippedPackage = makePackage(named: "chatgpt", kind: .cask)
        let visiblePackage = makePackage(named: "ripgrep", kind: .formula)
        let service = FakeHomebrewService(checkResponses: [
            .packages([skippedPackage, visiblePackage])
        ])
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        dependencies.preferences.rememberedSkippedPackageIDs = [skippedPackage.id]
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()

        XCTAssertEqual(model.visiblePackages, [visiblePackage])
        let updateCounts = await notifications.updateCounts()
        XCTAssertEqual(updateCounts, [1])
    }

    func testFailedCheckPostsFailureNotification() async {
        let diagnosticOutput = """
        fatal: unable to access 'https://github.com/Homebrew/brew/': Could not resolve host: github.com
        Failed to download https://formulae.brew.sh/api/formula.jws.json!
        """
        let service = FakeHomebrewService(checkResponses: [
            .failure(.commandFailed(HomebrewCommandFailure(
                operation: "check",
                exitCode: 1,
                output: diagnosticOutput
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
        XCTAssertEqual(
            failureMessages,
            ["Network unavailable. Check your connection and try again."]
        )
    }

    func testTimedOutCheckUsesSpecificStatusNotificationAndLog() async {
        let service = FakeHomebrewService(checkResponses: [
            .failure(.timedOut(
                operation: "update metadata",
                seconds: 60,
                output: "remote did not respond"
            ))
        ])
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies(now: Date(timeIntervalSince1970: 1_000))
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )

        _ = await model.checkUpdates()

        XCTAssertEqual(model.statusMessage, "Check timed out")
        let failureMessages = await notifications.failureMessages()
        XCTAssertEqual(failureMessages, ["Update Metadata timed out after 1 minute."])
        let entries = try? await dependencies.errorLogStore.entries(
            referenceDate: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(entries?.first?.output.contains("remote did not respond") == true)
    }

    func testPermissionFailureUsesCurrentGreedyModeInSingleBatch() async {
        let package = makePackage(named: "stats", kind: .cask)
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResult: UpdateResult(
                completedPackages: [],
                remainingPackages: [package],
                failures: [HomebrewCommandFailure(
                    operation: "upgrade casks",
                    exitCode: 1,
                    output: "sudo: authentication failed"
                )],
                timestamp: Date(timeIntervalSince1970: 500)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)
        model.greedyModeEnabled = true

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        let updateModes = await service.recordedUpdateGreedyValues()
        let updateBatches = await service.recordedUpdatePackageIDBatches()
        XCTAssertEqual(updateModes, [true])
        XCTAssertEqual(updateBatches, [[package.id]])
        XCTAssertEqual(model.availablePackages.map(\.id), [package.id])
    }
    func testFailedManualCheckDoesNotRecordSuccessfulCheckTimestamp() async {
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

        XCTAssertNil(dependencies.preferences.lastSuccessfulHomebrewCheckDate)
        XCTAssertNil(model.lastSuccessfulHomebrewCheckDate)
    }

    func testSuccessfulCheckRecordsSuccessfulCheckTimestamp() async {
        let startDate = Date(timeIntervalSince1970: 35_000)
        let completionDate = startDate.addingTimeInterval(120)
        let clock = MutableDateProvider(startDate)
        let dependencies = makeDependencies(now: startDate)
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: FakeHomebrewService(
                checkResponses: [.packages([])],
                onCheck: { clock.set(completionDate) }
            ),
            dependencies: dependencies,
            now: { clock.current() }
        )

        let succeeded = await model.checkUpdates()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            dependencies.preferences.lastSuccessfulHomebrewCheckDate,
            completionDate
        )
        XCTAssertEqual(model.lastSuccessfulHomebrewCheckDate, completionDate)
    }

    func testFailedAutomaticCheckRemainsEligibleForNextUnlock() async {
        let referenceDate = Date(timeIntervalSince1970: 40_000)
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

        model.startAutomaticChecks()
        model.scheduleCheckAfterUnlock(at: referenceDate)
        await waitUntil { await service.checkCount() == 1 }

        XCTAssertTrue(
            model.shouldRunHomebrewCheck(
                now: referenceDate.addingTimeInterval(1)
            )
        )
        XCTAssertNil(dependencies.preferences.lastSuccessfulHomebrewCheckDate)
    }

    func testFailedCheckDoesNotReplacePreviousSuccessfulCheckDate() async {
        let referenceDate = Date(timeIntervalSince1970: 50_000)
        let previousSuccess = referenceDate.addingTimeInterval(-18_000)
        let service = FakeHomebrewService(checkResponses: [
            .failure(.commandFailed(HomebrewCommandFailure(
                operation: "check",
                exitCode: 1,
                output: "failed"
            )))
        ])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        dependencies.preferences.lastSuccessfulHomebrewCheckDate = previousSuccess
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()

        XCTAssertEqual(
            dependencies.preferences.lastSuccessfulHomebrewCheckDate,
            previousSuccess
        )
        XCTAssertEqual(model.lastSuccessfulHomebrewCheckDate, previousSuccess)
    }

    func testManualCheckCanRetryImmediatelyAfterFailure() async {
        let referenceDate = Date(timeIntervalSince1970: 60_000)
        let service = FakeHomebrewService(checkResponses: [
            .failure(.networkUnavailable),
            .packages([])
        ])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        let firstSucceeded = await model.checkUpdates()
        let secondSucceeded = await model.checkUpdates()
        let checkCount = await service.checkCount()

        XCTAssertFalse(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(checkCount, 2)
        XCTAssertEqual(model.lastSuccessfulHomebrewCheckDate, referenceDate)
    }

    func testFailedCheckRemainsEligibleAfterRelaunch() async {
        let referenceDate = Date(timeIntervalSince1970: 70_000)
        let service = FakeHomebrewService(checkResponses: [
            .failure(.networkUnavailable)
        ])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let firstModel = makeModel(service: service, dependencies: dependencies)
        _ = await firstModel.checkUpdates()

        let relaunchedModel = makeModel(
            service: FakeHomebrewService(),
            dependencies: dependencies
        )

        XCTAssertTrue(
            relaunchedModel.shouldRunHomebrewCheck(
                now: referenceDate.addingTimeInterval(1)
            )
        )
    }

    func testRecentSuccessfulCheckPreventsSchedulingUnlockDelay() async {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        dependencies.preferences.lastSuccessfulHomebrewCheckDate = referenceDate
            .addingTimeInterval(-100)
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

    func testSecondIntervalGateSkipsCheckWhenAnotherCheckSucceedsDuringDelay() async {
        let referenceDate = Date(timeIntervalSince1970: 20_000)
        let service = FakeHomebrewService()
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        let preferences = dependencies.preferences
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            sleep: { _ in preferences.lastSuccessfulHomebrewCheckDate = referenceDate }
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

    func testChangingPeriodicIntervalPersistsAndReschedulesActiveTimer() async {
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        dependencies.preferences.periodicCheckInterval = 7_200
        let controller = ControlledSleeper()
        let model = makeModel(
            service: FakeHomebrewService(),
            dependencies: dependencies,
            sleep: { seconds in try await controller.sleep(seconds) }
        )
        model.automaticCheckMode = .periodic
        model.startAutomaticChecks()
        await waitUntil { await controller.totalCallCount() == 1 }

        model.setPeriodicCheckInterval(28_800)
        await waitUntil { await controller.totalCallCount() == 2 }
        await waitUntil { await controller.cancelledCallCount() >= 1 }
        model.stopAutomaticChecks()

        let intervals = await controller.recordedIntervals()
        XCTAssertEqual(model.periodicCheckInterval, 28_800)
        XCTAssertEqual(dependencies.preferences.periodicCheckInterval, 28_800)
        XCTAssertEqual(intervals, [7_200, 28_800])
    }

    func testPeriodicModeUsesSelectedIntervalWithoutUnlockThresholdGate() async {
        let referenceDate = Date(timeIntervalSince1970: 40_000)
        let service = FakeHomebrewService(checkResponses: [.packages([])])
        let dependencies = makeDependencies(now: referenceDate)
        defer { dependencies.cleanUp() }
        dependencies.preferences.lastSuccessfulHomebrewCheckDate = referenceDate
        dependencies.preferences.periodicCheckInterval = 3_600
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
        model.stopAutomaticChecks()

        let intervals = await controller.recordedIntervals()
        XCTAssertEqual(intervals.first, 3_600)
    }

    func testUpdateAllUpdatesFreshBrewLastAndFinalizesOneLogicalResult() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, freshBrew])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: formula)],
                    remainingPackages: [freshBrew],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 100)
                )),
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: freshBrew)],
                    remainingPackages: [],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 200)
                ))
            ],
            cleanupResponses: [.success(CleanupResult(
                isDeepCleanup: false,
                output: "This operation has freed approximately 42MB of disk space.",
                completedAt: Date(timeIntervalSince1970: 300)
            ))]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.checkUpdates()
        let result = await model.updateAll()
        let updateBatches = await service.recordedUpdatePackageIDBatches()
        let selfUpdateIDs = await service.recordedSelfUpdatePackageIDs()
        let cleanupValues = await service.recordedCleanupDeepValues()
        let completions = await notifications.completions()

        XCTAssertEqual(updateBatches, [[formula.id], [freshBrew.id]])
        XCTAssertEqual(selfUpdateIDs, [freshBrew.id])
        XCTAssertEqual(result?.completedPackages.map(\.id), [formula.id, freshBrew.id])
        XCTAssertEqual(model.latestUpdate?.packages.map(\.id), [formula.id, freshBrew.id])
        XCTAssertEqual(model.updateHistory.count, 1)
        XCTAssertTrue(model.restartRequired)
        XCTAssertEqual(cleanupValues, [false])
        XCTAssertEqual(
            completions,
            [UpdateCompletion(
                updatedCount: 2,
                remainingUpdateCount: 0,
                hadFailures: false,
                newlyAvailableCount: 0,
                cleanupOutcome: .completed(freedSpace: "42MB"),
                restartRequired: true
            )]
        )
    }

    func testUpdateAllDoesNotUpdateFreshBrewAfterEarlierFailure() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let failure = HomebrewCommandFailure(
            operation: "upgrade formulae",
            exitCode: 1,
            output: "formula failed"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, freshBrew])],
            updateResult: UpdateResult(
                completedPackages: [],
                remainingPackages: [formula, freshBrew],
                failures: [failure],
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        _ = await model.updateAll()
        let updateBatches = await service.recordedUpdatePackageIDBatches()
        let selfUpdateIDs = await service.recordedSelfUpdatePackageIDs()

        XCTAssertEqual(updateBatches, [[formula.id]])
        XCTAssertTrue(selfUpdateIDs.isEmpty)
        XCTAssertFalse(model.restartRequired)
        XCTAssertEqual(model.availablePackages.map(\.id), [formula.id, freshBrew.id])
    }

    func testUpdateAllDoesNotUpdateFreshBrewWhenEarlierVerificationIsUnavailable() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let verificationFailure = HomebrewCommandFailure(
            operation: "verify updates",
            exitCode: -1,
            output: "verification unavailable",
            kind: .timeout
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, freshBrew])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: formula)],
                remainingPackages: [freshBrew],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 100),
                verification: .unavailable(verificationFailure)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        _ = await model.updateAll()
        let updateBatches = await service.recordedUpdatePackageIDBatches()
        let selfUpdateIDs = await service.recordedSelfUpdatePackageIDs()

        XCTAssertEqual(updateBatches, [[formula.id]])
        XCTAssertTrue(selfUpdateIDs.isEmpty)
        XCTAssertEqual(model.latestUpdate?.packages.map(\.id), [formula.id])
        XCTAssertFalse(model.restartRequired)
    }

    func testFreshBrewOnlyUpdateUsesSelfUpdatePath() async {
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let service = FakeHomebrewService(
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: freshBrew)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.update(package: freshBrew)
        let selfUpdateIDs = await service.recordedSelfUpdatePackageIDs()

        XCTAssertEqual(selfUpdateIDs, [freshBrew.id])
        XCTAssertTrue(model.restartRequired)
    }

    func testVerifiedFreshBrewCommandStillRequiresRestartWhenVerificationIsUnavailable() async {
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let verificationFailure = HomebrewCommandFailure(
            operation: "verify updates",
            exitCode: -1,
            output: "verification unavailable",
            kind: .timeout
        )
        let service = FakeHomebrewService(
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: freshBrew)],
                remainingPackages: [],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 100),
                verification: .unavailable(verificationFailure)
            )
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.update(package: freshBrew)
        let cleanupValues = await service.recordedCleanupDeepValues()
        let completions = await notifications.completions()

        XCTAssertTrue(model.restartRequired)
        XCTAssertTrue(cleanupValues.isEmpty)
        XCTAssertEqual(
            completions,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 0,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil,
                verificationUnavailable: true,
                restartRequired: true
            )]
        )
    }

    func testFreshBrewFailureKeepsEarlierSuccessInOneHistoryAndNotification() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, freshBrew])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: formula)],
                    remainingPackages: [freshBrew],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 100)
                )),
                .success(UpdateResult(
                    completedPackages: [],
                    remainingPackages: [freshBrew],
                    failures: [HomebrewCommandFailure(
                        operation: "upgrade casks",
                        exitCode: 1,
                        output: "FreshBrew update failed"
                    )],
                    timestamp: Date(timeIntervalSince1970: 200)
                ))
            ]
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        model.autoCleanupEnabled = true

        _ = await model.checkUpdates()
        _ = await model.updateAll()
        let completions = await notifications.completions()
        let cleanupValues = await service.recordedCleanupDeepValues()

        XCTAssertEqual(model.updateHistory.count, 1)
        XCTAssertEqual(model.latestUpdate?.packages.map(\.id), [formula.id])
        XCTAssertEqual(model.availablePackages.map(\.id), [freshBrew.id])
        XCTAssertFalse(model.restartRequired)
        XCTAssertTrue(cleanupValues.isEmpty)
        XCTAssertEqual(
            completions,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 1,
                hadFailures: true,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
    }

    func testSkippedFreshBrewIsNotIncludedInSelfUpdatePhase() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let freshBrew = makePackage(named: "freshbrew", kind: .cask)
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, freshBrew])],
            updateResult: UpdateResult(
                completedPackages: [makeUpdatedPackage(from: formula)],
                remainingPackages: [freshBrew],
                failures: [],
                timestamp: Date(timeIntervalSince1970: 100)
            )
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        model.skip(freshBrew, remember: false)
        _ = await model.updateAll()
        let updateBatches = await service.recordedUpdatePackageIDBatches()
        let selfUpdateIDs = await service.recordedSelfUpdatePackageIDs()

        XCTAssertEqual(updateBatches, [[formula.id]])
        XCTAssertTrue(selfUpdateIDs.isEmpty)
        XCTAssertFalse(model.restartRequired)
    }

    private func makeModel(
        service: FakeHomebrewService,
        dependencies: ModelDependencies,
        notificationService: any NotificationServing = NoopNotificationService(),
        now: (@Sendable () -> Date)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> MenuBarModel {
        let referenceDate = dependencies.referenceDate
        return MenuBarModel(
            homebrewService: service,
            preferences: dependencies.preferences,
            historyStore: dependencies.historyStore,
            packageHomepageStore: dependencies.packageHomepageStore,
            errorLogStore: dependencies.errorLogStore,
            notificationService: notificationService,
            launchAtLoginService: FakeLaunchAtLoginService(),
            now: now ?? { referenceDate },
            sleep: sleep
        )
    }

    private func makeDependencies(now: Date = Date(timeIntervalSince1970: 10_000)) -> ModelDependencies {
        let defaults = InMemoryPreferencesStore()
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ModelDependencies(
            defaults: defaults,
            preferences: FreshBrewPreferences(defaults: defaults),
            historyStore: UpdateHistoryStore(defaults: defaults),
            packageHomepageStore: PackageHomepageStore(defaults: defaults),
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
    let defaults: InMemoryPreferencesStore
    let preferences: FreshBrewPreferences
    let historyStore: UpdateHistoryStore
    let packageHomepageStore: PackageHomepageStore
    let errorLogStore: HomebrewErrorLogStore
    let logDirectory: URL
    let referenceDate: Date

    func cleanUp() {
        try? FileManager.default.removeItem(at: logDirectory)
    }
}

private final class MutableDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func current() -> Date {
        lock.withLock { date }
    }

    func set(_ date: Date) {
        lock.withLock { self.date = date }
    }
}

private actor FakeHomebrewService: HomebrewServicing {
    enum CheckResponse: Sendable {
        case packages([HomebrewPackage])
        case failure(HomebrewError)
    }

    private var checkResponses: [CheckResponse]
    private var installedPackageResponses: [Result<[InstalledPackage], HomebrewError>]
    private var updateResponses: [Result<UpdateResult, HomebrewError>]
    private var checkGreedyValues: [Bool] = []
    private var updateGreedyValues: [Bool] = []
    private var updatePackageIDBatches: [[String]] = []
    private var selfUpdatePackageIDs: [String] = []
    private var cleanupResponses: [Result<CleanupResult, HomebrewError>]
    private var cleanupDeepValues: [Bool] = []
    private var homepageURLs: [String: URL] = [:]
    private let onCheck: (@Sendable () -> Void)?
    private let installedPackagesGate: ControlledSleeper?

    init(
        checkResponses: [CheckResponse] = [],
        installedPackageResponses: [Result<[InstalledPackage], HomebrewError>] = [],
        updateResult: UpdateResult? = nil,
        updateResponses: [Result<UpdateResult, HomebrewError>] = [],
        cleanupResponses: [Result<CleanupResult, HomebrewError>] = [],
        homepageURLs: [String: URL] = [:],
        onCheck: (@Sendable () -> Void)? = nil,
        installedPackagesGate: ControlledSleeper? = nil
    ) {
        self.checkResponses = checkResponses
        self.installedPackageResponses = installedPackageResponses
        self.cleanupResponses = cleanupResponses
        self.homepageURLs = homepageURLs
        self.onCheck = onCheck
        self.installedPackagesGate = installedPackagesGate
        if let updateResult {
            self.updateResponses = [.success(updateResult)]
        } else {
            self.updateResponses = updateResponses
        }
    }

    func installedPackages() async throws -> [InstalledPackage] {
        try await installedPackagesGate?.sleep(0)
        guard !installedPackageResponses.isEmpty else { return [] }
        return try installedPackageResponses.removeFirst().get()
    }

    func checkOutdated(
        greedy: Bool,
        refreshMetadata: Bool
    ) async throws -> [HomebrewPackage] {
        checkGreedyValues.append(greedy)
        onCheck?()
        guard !checkResponses.isEmpty else { return [] }
        switch checkResponses.removeFirst() {
        case let .packages(packages):
            return packages
        case let .failure(error):
            throw error
        }
    }

    func packageHomepageURLs(
        for packages: [HomebrewPackage]
    ) async -> [String: URL] {
        homepageURLs
    }

    func update(
        packages: [HomebrewPackage],
        greedy: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult {
        updateGreedyValues.append(greedy)
        updatePackageIDBatches.append(packages.map(\.id))
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

    func updateFreshBrew(
        package: HomebrewPackage,
        greedy: Bool,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult {
        updateGreedyValues.append(greedy)
        updatePackageIDBatches.append([package.id])
        selfUpdatePackageIDs.append(package.id)
        if !updateResponses.isEmpty {
            return try updateResponses.removeFirst().get()
        }
        return UpdateResult(
            completedPackages: [],
            remainingPackages: [package],
            failures: [],
            timestamp: Date()
        )
    }

    func cleanup(deep: Bool) async throws -> CleanupResult {
        cleanupDeepValues.append(deep)
        if !cleanupResponses.isEmpty {
            return try cleanupResponses.removeFirst().get()
        }
        return CleanupResult(isDeepCleanup: deep, output: "", completedAt: Date())
    }

    func recordedCheckGreedyValues() -> [Bool] {
        checkGreedyValues
    }

    func recordedUpdateGreedyValues() -> [Bool] {
        updateGreedyValues
    }

    func recordedUpdatePackageIDBatches() -> [[String]] {
        updatePackageIDBatches
    }

    func recordedSelfUpdatePackageIDs() -> [String] {
        selfUpdatePackageIDs
    }

    func checkCount() -> Int {
        checkGreedyValues.count
    }

    func recordedCleanupDeepValues() -> [Bool] {
        cleanupDeepValues
    }
}

private struct UpdateCompletion: Equatable, Sendable {
    let updatedCount: Int
    let remainingUpdateCount: Int
    let hadFailures: Bool
    let newlyAvailableCount: Int
    let cleanupOutcome: UpdateCleanupOutcome?
    let verificationUnavailable: Bool
    let restartRequired: Bool

    init(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool = false,
        restartRequired: Bool = false
    ) {
        self.updatedCount = updatedCount
        self.remainingUpdateCount = remainingUpdateCount
        self.hadFailures = hadFailures
        self.newlyAvailableCount = newlyAvailableCount
        self.cleanupOutcome = cleanupOutcome
        self.verificationUnavailable = verificationUnavailable
        self.restartRequired = restartRequired
    }
}

private actor FakeNotificationService: NotificationServing {
    private var counts: [Int] = []
    private var failures: [String] = []
    private var cleanupResultValues: [CleanupResult] = []
    private var cleanupFailureValues: [(deep: Bool, message: String)] = []
    private var completionValues: [UpdateCompletion] = []

    func requestAuthorization() async {}

    func postUpdatesAvailable(count: Int) async {
        guard count > 0 else { return }
        counts.append(count)
    }

    func postCheckFailure(message: String) async {
        failures.append(message)
    }

    func postCleanupResult(_ result: CleanupResult) async {
        cleanupResultValues.append(result)
    }

    func postCleanupFailure(deep: Bool, message: String) async {
        cleanupFailureValues.append((deep: deep, message: message))
    }

    func postUpdateResult(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool,
        restartRequired: Bool
    ) async {
        guard updatedCount > 0 || hadFailures else { return }
        completionValues.append(UpdateCompletion(
            updatedCount: updatedCount,
            remainingUpdateCount: remainingUpdateCount,
            hadFailures: hadFailures,
            newlyAvailableCount: newlyAvailableCount,
            cleanupOutcome: cleanupOutcome,
            verificationUnavailable: verificationUnavailable,
            restartRequired: restartRequired
        ))
    }

    func updateCounts() -> [Int] { counts }
    func failureMessages() -> [String] { failures }
    func cleanupResults() -> [CleanupResult] { cleanupResultValues }
    func cleanupFailures() -> [(deep: Bool, message: String)] { cleanupFailureValues }
    func completions() -> [UpdateCompletion] { completionValues }
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
