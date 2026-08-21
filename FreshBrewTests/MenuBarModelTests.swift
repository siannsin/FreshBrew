import Foundation
import XCTest
@testable import FreshBrew

@MainActor
final class MenuBarModelTests: XCTestCase {
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

    func testAdministratorRetryExcludesEvidenceCompletedBeforeUnavailableVerification() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let cask = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "permission denied"
        )
        let verificationFailure = HomebrewCommandFailure(
            operation: "verify updates",
            exitCode: -1,
            output: "verification timed out",
            kind: .timeout
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, cask])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: formula)],
                    remainingPackages: [cask],
                    failures: [permissionFailure],
                    timestamp: Date(timeIntervalSince1970: 500),
                    verification: .unavailable(verificationFailure)
                )),
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: cask)],
                    remainingPackages: [],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 501)
                ))
            ]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)

        _ = await model.checkUpdates()
        _ = await model.updateAll()
        XCTAssertTrue(model.administratorAccessRequired)
        _ = await model.retryLastUpdate(administratorPassword: "password")

        let updatePackageIDBatches = await service.recordedUpdatePackageIDBatches()
        XCTAssertEqual(
            updatePackageIDBatches,
            [[formula.id, cask.id], [cask.id]]
        )
        XCTAssertEqual(
            model.latestUpdate?.packages.map(\.name),
            ["ripgrep", "stats"]
        )
        XCTAssertTrue(model.availablePackages.isEmpty)
    }

    func testPermissionResultWaitsForAdministratorRetryBeforePostingNotification() async {
        let package = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: a password is required"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [],
                    remainingPackages: [package],
                    failures: [permissionFailure],
                    timestamp: Date(timeIntervalSince1970: 500)
                )),
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: package)],
                    remainingPackages: [],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 501)
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

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        XCTAssertTrue(model.administratorAccessRequired)
        let preRetryCompletions = await notifications.completions()
        XCTAssertTrue(preRetryCompletions.isEmpty)

        _ = await model.retryLastUpdate(administratorPassword: "secret")

        XCTAssertFalse(model.administratorAccessRequired)
        let postRetryCompletions = await notifications.completions()
        XCTAssertEqual(
            postRetryCompletions,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 0,
                hadFailures: false,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
    }

    func testAdministratorRetryPreservesInitialNewPackageBaseline() async {
        let package = makePackage(named: "stats", kind: .cask)
        let newlyAvailablePackage = makePackage(named: "wget", kind: .formula)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: a password is required"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([package])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [],
                    remainingPackages: [package, newlyAvailablePackage],
                    failures: [permissionFailure],
                    timestamp: Date(timeIntervalSince1970: 500)
                )),
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: package)],
                    remainingPackages: [newlyAvailablePackage],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 501)
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

        _ = await model.checkUpdates()
        _ = await model.updateAll()
        _ = await model.retryLastUpdate(administratorPassword: "secret")

        let completionValues = await notifications.completions()
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 1,
                remainingUpdateCount: 1,
                hadFailures: false,
                newlyAvailableCount: 1,
                cleanupOutcome: nil
            )]
        )
    }

    func testAdministratorRetryNotificationIncludesEarlierCompletedPackages() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let cask = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: a password is required"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, cask])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: formula)],
                    remainingPackages: [cask],
                    failures: [permissionFailure],
                    timestamp: Date(timeIntervalSince1970: 500)
                )),
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: cask)],
                    remainingPackages: [],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 501)
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
        let coordinator = UpdateActionCoordinator(
            model: model,
            passwordPrompt: FakeAdminPasswordPrompt(passwords: ["secret"])
        )

        _ = await model.checkUpdates()
        await coordinator.updateAll()

        let completionValues = await notifications.completions()
        XCTAssertEqual(
            completionValues,
            [UpdateCompletion(
                updatedCount: 2,
                remainingUpdateCount: 0,
                hadFailures: false,
                newlyAvailableCount: 0,
                cleanupOutcome: nil
            )]
        )
        XCTAssertEqual(model.updateHistory.count, 1)
        XCTAssertEqual(
            model.latestUpdate?.packages.map(\.name),
            ["ripgrep", "stats"]
        )
    }

    func testAdministratorRetryRunsAutomaticCleanupOnceAfterFinalSuccess() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let cask = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: a password is required"
        )
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, cask])],
            updateResponses: [
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: formula)],
                    remainingPackages: [cask],
                    failures: [permissionFailure],
                    timestamp: Date(timeIntervalSince1970: 500)
                )),
                .success(UpdateResult(
                    completedPackages: [makeUpdatedPackage(from: cask)],
                    remainingPackages: [],
                    failures: [],
                    timestamp: Date(timeIntervalSince1970: 501)
                ))
            ]
        )
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(service: service, dependencies: dependencies)
        model.autoCleanupEnabled = true

        _ = await model.checkUpdates()
        _ = await model.updateAll()

        XCTAssertTrue(model.updateHistory.isEmpty)
        let cleanupBeforeRetry = await service.recordedCleanupDeepValues()
        XCTAssertTrue(cleanupBeforeRetry.isEmpty)

        _ = await model.retryLastUpdate(administratorPassword: "secret")

        let cleanupAfterRetry = await service.recordedCleanupDeepValues()
        XCTAssertEqual(cleanupAfterRetry, [false])
        XCTAssertEqual(model.updateHistory.count, 1)
        XCTAssertEqual(model.latestUpdate?.packages.count, 2)
    }

    func testThreeFailedPasswordAttemptsPreserveEarlierCompletedPackages() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let cask = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: """
            Application 'com.example.stats' quit successfully.
            sudo: a password is required
            """
        )
        let initialResponse: Result<UpdateResult, HomebrewError> = .success(UpdateResult(
            completedPackages: [makeUpdatedPackage(from: formula)],
            remainingPackages: [cask],
            failures: [permissionFailure],
            timestamp: Date(timeIntervalSince1970: 500)
        ))
        let retryResponse: Result<UpdateResult, HomebrewError> = .success(UpdateResult(
            completedPackages: [],
            remainingPackages: [cask],
            failures: [permissionFailure],
            timestamp: Date(timeIntervalSince1970: 501)
        ))
        let service = FakeHomebrewService(
            checkResponses: [.packages([formula, cask])],
            updateResponses: [initialResponse] + Array(repeating: retryResponse, count: 3)
        )
        let notifications = FakeNotificationService()
        let dependencies = makeDependencies()
        defer { dependencies.cleanUp() }
        let model = makeModel(
            service: service,
            dependencies: dependencies,
            notificationService: notifications
        )
        let coordinator = UpdateActionCoordinator(
            model: model,
            passwordPrompt: FakeAdminPasswordPrompt(
                passwords: ["wrong-1", "wrong-2", "wrong-3"]
            )
        )

        _ = await model.checkUpdates()
        await coordinator.updateAll()

        let completionValues = await notifications.completions()
        let passwords = await service.recordedAdministratorPasswords()
        XCTAssertFalse(model.administratorAccessRequired)
        XCTAssertEqual(passwords, [nil, "wrong-1", "wrong-2", "wrong-3"])
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
        XCTAssertEqual(model.updateHistory.count, 1)
        XCTAssertEqual(model.latestUpdate?.packages.map(\.name), ["ripgrep"])
    }

    func testCancellingPasswordPromptReportsEarlierCompletedPackages() async {
        let formula = makePackage(named: "ripgrep", kind: .formula)
        let cask = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: a password is required"
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
        let coordinator = UpdateActionCoordinator(
            model: model,
            passwordPrompt: FakeAdminPasswordPrompt(passwords: [])
        )

        _ = await model.checkUpdates()
        await coordinator.updateAll()

        let completionValues = await notifications.completions()
        XCTAssertFalse(model.administratorAccessRequired)
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
        XCTAssertEqual(model.updateHistory.count, 1)
        XCTAssertEqual(model.latestUpdate?.packages.map(\.name), ["ripgrep"])
    }

    func testCancellingPasswordPromptWithoutSuccessPostsFailureNotification() async {
        let package = makePackage(named: "stats", kind: .cask)
        let permissionFailure = HomebrewCommandFailure(
            operation: "upgrade casks",
            exitCode: 1,
            output: "sudo: a password is required"
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
        let coordinator = UpdateActionCoordinator(
            model: model,
            passwordPrompt: FakeAdminPasswordPrompt(passwords: [])
        )

        _ = await model.checkUpdates()
        await coordinator.updateAll()

        let completionValues = await notifications.completions()
        XCTAssertFalse(model.administratorAccessRequired)
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
    private var updateResponses: [Result<UpdateResult, HomebrewError>]
    private var checkGreedyValues: [Bool] = []
    private var updateGreedyValues: [Bool] = []
    private var updatePackageIDBatches: [[String]] = []
    private var administratorPasswords: [String?] = []
    private var cleanupResponses: [Result<CleanupResult, HomebrewError>]
    private var cleanupDeepValues: [Bool] = []
    private var homepageURLs: [String: URL] = [:]
    private let onCheck: (@Sendable () -> Void)?

    init(
        checkResponses: [CheckResponse] = [],
        updateResult: UpdateResult? = nil,
        updateResponses: [Result<UpdateResult, HomebrewError>] = [],
        cleanupResponses: [Result<CleanupResult, HomebrewError>] = [],
        homepageURLs: [String: URL] = [:],
        onCheck: (@Sendable () -> Void)? = nil
    ) {
        self.checkResponses = checkResponses
        self.cleanupResponses = cleanupResponses
        self.homepageURLs = homepageURLs
        self.onCheck = onCheck
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
        administratorPassword: String?,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws -> UpdateResult {
        updateGreedyValues.append(greedy)
        updatePackageIDBatches.append(packages.map(\.id))
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

    func recordedAdministratorPasswords() -> [String?] {
        administratorPasswords
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

    init(
        updatedCount: Int,
        remainingUpdateCount: Int,
        hadFailures: Bool,
        newlyAvailableCount: Int,
        cleanupOutcome: UpdateCleanupOutcome?,
        verificationUnavailable: Bool = false
    ) {
        self.updatedCount = updatedCount
        self.remainingUpdateCount = remainingUpdateCount
        self.hadFailures = hadFailures
        self.newlyAvailableCount = newlyAvailableCount
        self.cleanupOutcome = cleanupOutcome
        self.verificationUnavailable = verificationUnavailable
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
        verificationUnavailable: Bool
    ) async {
        guard updatedCount > 0 || hadFailures else { return }
        completionValues.append(UpdateCompletion(
            updatedCount: updatedCount,
            remainingUpdateCount: remainingUpdateCount,
            hadFailures: hadFailures,
            newlyAvailableCount: newlyAvailableCount,
            cleanupOutcome: cleanupOutcome,
            verificationUnavailable: verificationUnavailable
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

@MainActor
private final class FakeAdminPasswordPrompt: AdminPasswordPrompting {
    private var passwords: [String]

    init(passwords: [String]) {
        self.passwords = passwords
    }

    func requestPassword() async -> String? {
        guard !passwords.isEmpty else { return nil }
        return passwords.removeFirst()
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
