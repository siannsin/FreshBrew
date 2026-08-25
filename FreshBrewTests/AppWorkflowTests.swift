import AppKit
import XCTest
@testable import FreshBrew

private final class MenuActionTarget: NSObject {
    @objc func performAction(_ sender: NSMenuItem) {}
}

private struct StubPackageHomepageResolver: PackageHomepageResolving {
    let homepageURL: URL

    func packageHomepageURLs(
        for packages: [HomebrewPackage]
    ) async -> [String: URL] {
        Dictionary(uniqueKeysWithValues: packages.map { ($0.id, homepageURL) })
    }

    func packageHomepageURL(
        packageName: String,
        kind: HomebrewPackageKind
    ) async throws -> URL {
        homepageURL
    }
}

@MainActor
final class AppWorkflowTests: XCTestCase {
    func testPackageHomepageServiceOpensResolvedHomepageWithInjectedBrowser() async throws {
        var openedURL: URL?
        let homepageURL = try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        let service = PackageHomepageService(
            homepageResolver: StubPackageHomepageResolver(homepageURL: homepageURL),
            openURL: { url in
                openedURL = url
                return true
            }
        )

        let opened = try await service.openPage(
            packageName: "chatgpt",
            kind: .cask,
            homepageURL: nil
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(openedURL, homepageURL)
    }

    func testPackageHomepageServiceUsesStoredURLWithoutResolvingAgain() async throws {
        let defaults = InMemoryPreferencesStore()
        let store = PackageHomepageStore(defaults: defaults)
        let homepageURL = try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        store.save(["cask:chatgpt": homepageURL])
        var openedURL: URL?
        let service = PackageHomepageService(
            homepageResolver: StubPackageHomepageResolver(
                homepageURL: URL(string: "https://example.com/fallback")!
            ),
            store: store,
            openURL: { url in
                openedURL = url
                return true
            }
        )

        _ = try await service.openPage(
            packageName: "chatgpt",
            kind: .cask,
            homepageURL: nil
        )

        XCTAssertEqual(openedURL, homepageURL)
    }

    func testAvailablePackageVersionIsClickableWithoutChangingPackageActions() {
        let target = MenuActionTarget()
        let action = #selector(MenuActionTarget.performAction(_:))
        let package = HomebrewPackage(
            name: "wget",
            installedVersion: "1.0",
            availableVersion: "2.0",
            kind: .formula
        )

        let packageItem = MenuBarController.makeAvailablePackageMenuItem(
            package: package,
            target: target,
            openPageAction: action,
            updateAction: action,
            skipOnceAction: action,
            alwaysSkipAction: action,
            updatesEnabled: false
        )

        let items = packageItem.submenu?.items
        XCTAssertNotNil(packageItem.submenu)
        XCTAssertEqual(items?.map(\.title), [
            "1.0 → 2.0",
            "",
            "Update",
            "Skip This Time",
            "Always Skip"
        ])
        XCTAssertEqual(items?.first?.action, action)
        XCTAssertTrue(items?.first?.isEnabled == true)
        XCTAssertEqual(items?.first?.representedObject as? HomebrewPackage, package)
        XCTAssertTrue(items?.dropFirst(2).allSatisfy { !$0.isEnabled } == true)
    }

    func testLastUpdatePackageItemIsClickableWithExistingLabel() {
        let target = MenuActionTarget()
        let action = #selector(MenuActionTarget.performAction(_:))
        let package = UpdatedPackage(
            name: "wget",
            previousVersion: "1.0",
            installedVersion: "2.0",
            kind: .formula
        )

        let item = MenuBarController.makeLastUpdatePackageItem(
            package: package,
            title: "wget 2.0",
            target: target,
            openPageAction: action
        )

        XCTAssertEqual(item.title, "wget 2.0")
        XCTAssertEqual(item.action, action)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.representedObject as? UpdatedPackage, package)
        XCTAssertNil(item.image)
    }

    func testNotificationActionRouterHandlesOnlyUpdateAllAction() async {
        var calls = 0
        var releaseURLs: [String] = []
        var restartCalls = 0
        let router = NotificationActionRouter(
            updateAll: { calls += 1 },
            viewRelease: { url in
                releaseURLs.append(url)
                return true
            },
            restartApplication: { restartCalls += 1 }
        )

        let ignored = await router.handle(actionIdentifier: "unrelated")
        let handled = await router.handle(
            actionIdentifier: NotificationService.updateAllActionIdentifier
        )
        let releaseHandled = await router.handle(
            actionIdentifier: NotificationService.viewReleaseActionIdentifier,
            releasePageURL: "https://github.com/siannsin/FreshBrew/releases/tag/v0.2.0"
        )
        let restartHandled = await router.handle(
            actionIdentifier: NotificationService.restartActionIdentifier
        )

        XCTAssertFalse(ignored)
        XCTAssertTrue(handled)
        XCTAssertTrue(releaseHandled)
        XCTAssertTrue(restartHandled)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(restartCalls, 1)
        XCTAssertEqual(
            releaseURLs,
            ["https://github.com/siannsin/FreshBrew/releases/tag/v0.2.0"]
        )
    }

    func testRelaunchServiceLaunchesCurrentBundleBeforeTerminating() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/FreshBrew.app")
        var launchedURL: URL?
        var didTerminate = false
        let service = ApplicationRelaunchService(
            bundleURL: bundleURL,
            bundleValidator: { $0 == bundleURL },
            relaunchLauncher: { launchedURL = $0 },
            terminator: { didTerminate = true }
        )

        try service.relaunch()

        XCTAssertEqual(launchedURL, bundleURL)
        XCTAssertTrue(didTerminate)
    }

    func testRelaunchServiceKeepsAppRunningWhenPreparationFails() {
        var didLaunch = false
        var didTerminate = false
        let service = ApplicationRelaunchService(
            bundleURL: URL(fileURLWithPath: "/tmp/FreshBrew"),
            bundleValidator: { _ in false },
            relaunchLauncher: { _ in didLaunch = true },
            terminator: { didTerminate = true }
        )

        XCTAssertThrowsError(try service.relaunch())
        XCTAssertFalse(didLaunch)
        XCTAssertFalse(didTerminate)
    }

    func testSingleInstanceGuardIgnoresCurrentProcess() {
        XCTAssertFalse(SingleInstanceGuard.shouldTerminateNewInstance(
            currentProcessIdentifier: 10,
            runningProcessIdentifiers: [10]
        ))
        XCTAssertTrue(SingleInstanceGuard.shouldTerminateNewInstance(
            currentProcessIdentifier: 10,
            runningProcessIdentifiers: [9, 10]
        ))
    }
}
