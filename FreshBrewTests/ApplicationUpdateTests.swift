import Foundation
import XCTest
@testable import FreshBrew

private struct StubApplicationUpdateHTTPClient: ApplicationUpdateHTTPClient {
    let responseData: Data
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url ?? GitHubApplicationUpdateService.latestReleaseURL,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (responseData, response)
    }
}

private actor StubApplicationUpdateChecker: ApplicationUpdateChecking {
    enum Response: Sendable {
        case result(ApplicationUpdateCheckResult)
        case failure(URLError)
    }

    private let response: Response
    private var calls = 0

    init(response: Response) {
        self.response = response
    }

    func check() async throws -> ApplicationUpdateCheckResult {
        calls += 1
        switch response {
        case let .result(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func callCount() -> Int { calls }
}

private actor RecordingApplicationUpdateNotificationService:
    ApplicationUpdateNotificationServing {
    private var values: [(String, URL)] = []

    func postApplicationUpdateAvailable(
        version: String,
        releasePageURL: URL
    ) async {
        values.append((version, releasePageURL))
    }

    func notifications() -> [(String, URL)] { values }
}

final class ApplicationUpdateServiceTests: XCTestCase {
    func testSemanticVersionUsesNumericComparison() throws {
        let older = try XCTUnwrap(SemanticVersion("v0.9.0"))
        let newer = try XCTUnwrap(SemanticVersion("0.10.0"))

        XCTAssertLessThan(older, newer)
        XCTAssertEqual(newer.displayValue, "0.10.0")
        XCTAssertNil(SemanticVersion("0.10"))
        XCTAssertNil(SemanticVersion("release-0.10.0"))
    }

    func testGitHubServiceDetectsNewerRelease() async throws {
        let service = GitHubApplicationUpdateService(
            installedVersion: "0.1.0",
            httpClient: StubApplicationUpdateHTTPClient(
                responseData: releaseJSON(tag: "v0.2.0"),
                statusCode: 200
            )
        )

        let result = try await service.check()
        guard case let .updateAvailable(release) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(release.displayVersion, "0.2.0")
        XCTAssertEqual(
            release.pageURL.absoluteString,
            "https://github.com/siannsin/FreshBrew/releases/tag/v0.2.0"
        )
    }

    func testGitHubServiceTreatsEqualAndOlderReleasesAsCurrent() async throws {
        for tag in ["v0.2.0", "v0.1.9"] {
            let service = GitHubApplicationUpdateService(
                installedVersion: "0.2.0",
                httpClient: StubApplicationUpdateHTTPClient(
                    responseData: releaseJSON(tag: tag),
                    statusCode: 200
                )
            )
            let result = try await service.check()
            XCTAssertEqual(result, .current)
        }
    }

    func testGitHubServiceRejectsMalformedOrUntrustedRelease() async {
        let malformedVersion = GitHubApplicationUpdateService(
            installedVersion: "0.1.0",
            httpClient: StubApplicationUpdateHTTPClient(
                responseData: releaseJSON(tag: "latest"),
                statusCode: 200
            )
        )
        let untrustedURL = GitHubApplicationUpdateService(
            installedVersion: "0.1.0",
            httpClient: StubApplicationUpdateHTTPClient(
                responseData: releaseJSON(
                    tag: "v0.2.0",
                    pageURL: "https://example.com/releases/tag/v0.2.0"
                ),
                statusCode: 200
            )
        )

        await XCTAssertThrowsErrorAsync(try await malformedVersion.check())
        await XCTAssertThrowsErrorAsync(try await untrustedURL.check())
    }

    func testGitHubServiceRejectsIncompleteReleaseResponse() async {
        let service = GitHubApplicationUpdateService(
            installedVersion: "0.1.0",
            httpClient: StubApplicationUpdateHTTPClient(
                responseData: Data("{\"tag_name\":\"v0.2.0\"}".utf8),
                statusCode: 200
            )
        )

        await XCTAssertThrowsErrorAsync(try await service.check())
    }

    func testGitHubServiceRejectsFailedHTTPResponse() async {
        let service = GitHubApplicationUpdateService(
            installedVersion: "0.1.0",
            httpClient: StubApplicationUpdateHTTPClient(
                responseData: Data(),
                statusCode: 503
            )
        )

        do {
            _ = try await service.check()
            XCTFail("Expected request failure")
        } catch {
            XCTAssertEqual(
                error as? ApplicationUpdateError,
                .requestFailed(statusCode: 503)
            )
        }
    }

    private func releaseJSON(
        tag: String,
        pageURL: String? = nil
    ) -> Data {
        let pageURL = pageURL
            ?? "https://github.com/siannsin/FreshBrew/releases/tag/\(tag)"
        return Data("""
        {
          "tag_name": "\(tag)",
          "html_url": "\(pageURL)",
          "published_at": "2026-08-16T00:00:00Z",
          "draft": false,
          "prerelease": false
        }
        """.utf8)
    }
}

@MainActor
final class ApplicationUpdateCoordinatorTests: XCTestCase {
    func testManualCheckReportsCurrentVersion() async {
        let coordinator = ApplicationUpdateCoordinator(
            checker: StubApplicationUpdateChecker(response: .result(.current)),
            preferences: FreshBrewPreferences(defaults: InMemoryPreferencesStore()),
            notificationService: NoopApplicationUpdateNotificationService()
        )

        await coordinator.checkManually()

        XCTAssertEqual(coordinator.manualState, .current)
    }

    func testManualCheckWorksWhenBackgroundChecksAreDisabled() async throws {
        let defaults = InMemoryPreferencesStore()
        let preferences = FreshBrewPreferences(defaults: defaults)
        preferences.appUpdateChecksEnabled = false
        let release = try makeRelease(version: "0.2.0")
        let checker = StubApplicationUpdateChecker(
            response: .result(.updateAvailable(release))
        )
        let notifications = RecordingApplicationUpdateNotificationService()
        let now = Date(timeIntervalSince1970: 1_000)
        let coordinator = ApplicationUpdateCoordinator(
            checker: checker,
            preferences: preferences,
            notificationService: notifications,
            now: { now }
        )

        await coordinator.checkManually()

        XCTAssertEqual(coordinator.manualState, .updateAvailable(release))
        XCTAssertEqual(preferences.lastSuccessfulAppUpdateCheckDate, now)
        let postedNotifications = await notifications.notifications()
        XCTAssertTrue(postedNotifications.isEmpty)
    }

    func testBackgroundCheckRespectsIntervalAndNotifiesReleaseOnce() async throws {
        let defaults = InMemoryPreferencesStore()
        let preferences = FreshBrewPreferences(defaults: defaults)
        let release = try makeRelease(version: "0.2.0")
        let checker = StubApplicationUpdateChecker(
            response: .result(.updateAvailable(release))
        )
        let notifications = RecordingApplicationUpdateNotificationService()
        let coordinator = ApplicationUpdateCoordinator(
            checker: checker,
            preferences: preferences,
            notificationService: notifications
        )
        let firstDate = Date(timeIntervalSince1970: 100_000)

        let firstAttempt = await coordinator.checkInBackgroundIfNeeded(at: firstDate)
        let throttledAttempt = await coordinator.checkInBackgroundIfNeeded(
            at: firstDate.addingTimeInterval(3_600)
        )
        let secondAttempt = await coordinator.checkInBackgroundIfNeeded(
            at: firstDate.addingTimeInterval(86_400)
        )

        XCTAssertTrue(firstAttempt)
        XCTAssertFalse(throttledAttempt)
        XCTAssertTrue(secondAttempt)
        let checkerCalls = await checker.callCount()
        XCTAssertEqual(checkerCalls, 2)
        let posted = await notifications.notifications()
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.0, "0.2.0")
        XCTAssertEqual(posted.first?.1, release.pageURL)
    }

    func testFailedBackgroundCheckDoesNotAdvanceSuccessfulDate() async {
        let defaults = InMemoryPreferencesStore()
        let preferences = FreshBrewPreferences(defaults: defaults)
        let checker = StubApplicationUpdateChecker(
            response: .failure(URLError(.notConnectedToInternet))
        )
        let coordinator = ApplicationUpdateCoordinator(
            checker: checker,
            preferences: preferences,
            notificationService: NoopApplicationUpdateNotificationService()
        )

        let attempted = await coordinator.checkInBackgroundIfNeeded()
        XCTAssertTrue(attempted)
        XCTAssertNil(preferences.lastSuccessfulAppUpdateCheckDate)
    }

    func testFailedStaleBackgroundCheckUsesHourlyRetryDelay() async {
        let defaults = InMemoryPreferencesStore()
        let preferences = FreshBrewPreferences(defaults: defaults)
        let previousSuccess = Date(timeIntervalSince1970: 1_000)
        preferences.lastSuccessfulAppUpdateCheckDate = previousSuccess
        let checker = StubApplicationUpdateChecker(
            response: .failure(URLError(.notConnectedToInternet))
        )
        let coordinator = ApplicationUpdateCoordinator(
            checker: checker,
            preferences: preferences,
            notificationService: NoopApplicationUpdateNotificationService(),
            now: { previousSuccess.addingTimeInterval(86_500) }
        )

        let attempted = await coordinator.checkInBackgroundIfNeeded()

        XCTAssertTrue(attempted)
        XCTAssertEqual(
            coordinator.nextBackgroundDelay(),
            ApplicationUpdateCoordinator.failedCheckRetryInterval
        )
        XCTAssertEqual(preferences.lastSuccessfulAppUpdateCheckDate, previousSuccess)
    }

    func testDisablingChecksDuringBackgroundRequestSuppressesNotification() async throws {
        let defaults = InMemoryPreferencesStore()
        let preferences = FreshBrewPreferences(defaults: defaults)
        let release = try makeRelease(version: "0.2.0")
        let checker = SuspendedApplicationUpdateChecker(result: .updateAvailable(release))
        let notifications = RecordingApplicationUpdateNotificationService()
        let coordinator = ApplicationUpdateCoordinator(
            checker: checker,
            preferences: preferences,
            notificationService: notifications
        )

        let checkTask = Task { await coordinator.checkInBackgroundIfNeeded() }
        await checker.waitUntilStarted()
        coordinator.checksEnabled = false
        await checker.resume()
        _ = await checkTask.value

        let posted = await notifications.notifications()
        XCTAssertTrue(posted.isEmpty)
        XCTAssertNil(preferences.lastSuccessfulAppUpdateCheckDate)
    }

    func testManualFailureUsesConciseNetworkMessage() async {
        let checker = StubApplicationUpdateChecker(
            response: .failure(URLError(.timedOut))
        )
        let coordinator = ApplicationUpdateCoordinator(
            checker: checker,
            preferences: FreshBrewPreferences(defaults: InMemoryPreferencesStore()),
            notificationService: NoopApplicationUpdateNotificationService()
        )

        await coordinator.checkManually()

        XCTAssertEqual(
            coordinator.manualState,
            .failed("Could not connect to GitHub.")
        )
    }

    func testReleaseOpeningAcceptsOnlyFreshBrewGitHubReleasePages() throws {
        var openedURLs: [URL] = []
        let release = try makeRelease(version: "0.2.0")
        let coordinator = ApplicationUpdateCoordinator(
            checker: StubApplicationUpdateChecker(response: .result(.current)),
            preferences: FreshBrewPreferences(defaults: InMemoryPreferencesStore()),
            notificationService: NoopApplicationUpdateNotificationService(),
            openURL: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(coordinator.openReleasePage(from: release.pageURL.absoluteString))
        XCTAssertFalse(coordinator.openReleasePage(
            from: "https://example.com/siannsin/FreshBrew/releases/tag/v0.2.0"
        ))
        XCTAssertEqual(openedURLs, [release.pageURL])
    }

    private func makeRelease(version: String) throws -> ApplicationRelease {
        let semanticVersion = try XCTUnwrap(SemanticVersion(version))
        let pageURL = try XCTUnwrap(URL(
            string: "https://github.com/siannsin/FreshBrew/releases/tag/v\(version)"
        ))
        return ApplicationRelease(
            version: semanticVersion,
            pageURL: pageURL,
            publishedAt: nil
        )
    }
}

private actor SuspendedApplicationUpdateChecker: ApplicationUpdateChecking {
    private let result: ApplicationUpdateCheckResult
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    init(result: ApplicationUpdateCheckResult) {
        self.result = result
    }

    func check() async throws -> ApplicationUpdateCheckResult {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return result
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
