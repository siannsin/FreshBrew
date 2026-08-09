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
        let router = NotificationActionRouter { calls += 1 }

        let ignored = await router.handle(actionIdentifier: "unrelated")
        let handled = await router.handle(
            actionIdentifier: NotificationService.updateAllActionIdentifier
        )

        XCTAssertFalse(ignored)
        XCTAssertTrue(handled)
        XCTAssertEqual(calls, 1)
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
