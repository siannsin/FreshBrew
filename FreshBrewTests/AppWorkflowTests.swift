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

private struct EmptyInventoryCommandRunner: CommandRunning {
    func run(
        _ request: CommandRequest,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: #"{"formulae":[],"casks":[]}"#, standardError: "")
    }
}

@MainActor
final class AppWorkflowTests: XCTestCase {
    func testPackageCommandsSelectTheirTabsAndReuseOneResizableWindow() async throws {
        let autosaveKey = "NSWindow Frame FreshBrew.packages"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        UserDefaults.standard.removeObject(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }

        let presenter = makeWindowPresenter()
        let controller = presenter.showInstalledPackages()
        let window = try XCTUnwrap(controller.window)
        let contentController = window.contentViewController
        defer {
            controller.windowFrameAutosaveName = ""
            window.close()
        }

        XCTAssertEqual(presenter.packagesWindowState.selectedTab, .installed)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(window.title, "Installed Packages")
        XCTAssertEqual(window.frameAutosaveName, "FreshBrew.packages")
        XCTAssertEqual(window.contentMinSize, NSSize(width: 380, height: 300))
        XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 400, height: 320))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMaxSize.width, 640)
        XCTAssertGreaterThan(window.contentMaxSize.height, 1_000)

        XCTAssertTrue(presenter.showUpdateHistory() === controller)
        XCTAssertEqual(presenter.packagesWindowState.selectedTab, .history)
        XCTAssertTrue(presenter.showSkippedPackages() === controller)
        XCTAssertEqual(presenter.packagesWindowState.selectedTab, .skipped)
        XCTAssertTrue(window.contentViewController === contentController)

        window.setContentSize(NSSize(width: 640, height: 600))
        window.close()
        XCTAssertTrue(presenter.showUpdateHistory() === controller)
        XCTAssertEqual(presenter.packagesWindowState.selectedTab, .history)
        XCTAssertEqual(window.contentLayoutRect.size, NSSize(width: 640, height: 600))

        let aboutController = presenter.showAbout()
        defer { aboutController.close() }
        XCTAssertFalse(aboutController === controller)
        XCTAssertFalse(aboutController.window?.styleMask.contains(.resizable) ?? true)
        XCTAssertEqual(aboutController.window?.title, "About FreshBrew")
    }

    func testHistoryAndSkippedCommandsSelectCorrectTabOnFirstPresentation() async throws {
        let autosaveKey = "NSWindow Frame FreshBrew.packages"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }

        for tab in [PackagesWindowState.Tab.history, .skipped] {
            let presenter = makeWindowPresenter()
            let controller = tab == .history
                ? presenter.showUpdateHistory()
                : presenter.showSkippedPackages()
            XCTAssertEqual(presenter.packagesWindowState.selectedTab, tab)
            controller.window?.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(controller.window?.title, tab == .history ? "Update History" : "Skipped Packages")
            controller.windowFrameAutosaveName = ""
            controller.close()
        }
    }

    func testPackagesWindowRestoresSavedSizeForAnyTab() throws {
        let autosaveName = "FreshBrew.packages"
        let autosaveKey = "NSWindow Frame \(autosaveName)"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }

        let firstPresenter = makeWindowPresenter()
        let firstController = firstPresenter.showUpdateHistory()
        let firstWindow = try XCTUnwrap(firstController.window)
        // Simulate a saved frame from before the width limit was introduced.
        firstWindow.contentMaxSize.width = 800
        firstWindow.setContentSize(NSSize(width: 800, height: 480))
        firstWindow.saveFrame(usingName: autosaveName)
        firstController.windowFrameAutosaveName = ""
        firstController.close()

        let nextPresenter = makeWindowPresenter()
        let nextController = nextPresenter.showSkippedPackages()
        defer {
            nextController.windowFrameAutosaveName = ""
            nextController.close()
        }
        XCTAssertEqual(nextPresenter.packagesWindowState.selectedTab, .skipped)
        XCTAssertEqual(nextController.window?.contentLayoutRect.size, NSSize(width: 640, height: 480))
    }

    func testPackageTitleBarOverflowHasNativeLabelsAndWorkingTabActions() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Title-bar tab presentation requires macOS 26.")
        }
        let autosaveKey = "NSWindow Frame FreshBrew.packages"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }

        let presenter = makeWindowPresenter(skippedPackageCount: 99)
        let controller = presenter.showUpdateHistory()
        let window = try XCTUnwrap(controller.window)
        defer {
            controller.windowFrameAutosaveName = ""
            controller.close()
        }
        window.setContentSize(NSSize(width: 380, height: 300))
        await Task.yield()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(toolbar.items.count, 1)
        func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
        }
        let tabRootView = try XCTUnwrap(toolbar.items.first?.view)
        let tabs = try XCTUnwrap(segmentedControl(in: tabRootView))
        let tabFont = try XCTUnwrap(tabs.font)
        XCTAssertEqual(
            tabFont.fontName,
            NSFont.monospacedDigitSystemFont(ofSize: tabFont.pointSize, weight: .regular).fontName
        )
        let tabAttributes: [NSAttributedString.Key: Any] = [.font: tabFont]
        XCTAssertEqual(
            ("1" as NSString).size(withAttributes: tabAttributes).width,
            ("8" as NSString).size(withAttributes: tabAttributes).width,
            accuracy: 0.01
        )

        for (index, tab) in [PackagesWindowState.Tab.installed, .history, .skipped].enumerated() {
            let item = try XCTUnwrap(toolbar.items.first)
            let representation = try XCTUnwrap(item.menuFormRepresentation)
            // Simulate SwiftUI replacing the menu after content layout has finished.
            item.menuFormRepresentation = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            XCTAssertTrue(item.menuFormRepresentation === representation)
            let menu = try XCTUnwrap(representation.submenu)
            let overflowMenu = NSMenu()
            overflowMenu.addItem(try XCTUnwrap(representation.copy() as? NSMenuItem))
            overflowMenu.update()
            XCTAssertEqual(overflowMenu.items.map(\.title), ["Installed", "History", "Skipped (99)"])
            XCTAssertTrue(overflowMenu.items.allSatisfy { $0.submenu == nil })
            menu.update()
            XCTAssertTrue(type(of: representation) == NSMenuItem.self)
            XCTAssertEqual(menu.items.map(\.title), ["Installed", "History", "Skipped (99)"])
            for menuItem in menu.items {
                XCTAssertTrue(type(of: menuItem) == NSMenuItem.self)
                XCTAssertNil(menuItem.view, "Overflow labels must use native text rendering.")
            }
            overflowMenu.performActionForItem(at: index)
            await Task.yield()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(presenter.packagesWindowState.selectedTab, tab)
            XCTAssertEqual(window.title, ["Installed Packages", "Update History", "Skipped Packages"][index])
            XCTAssertEqual(window.titleVisibility, .visible)
            menu.update()
            XCTAssertEqual(menu.items.map(\.state), (0..<3).map { $0 == index ? .on : .off })

            window.setContentSize(NSSize(width: 640, height: 600))
            await Task.yield()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertFalse(toolbar.visibleItems?.isEmpty ?? true)
            XCTAssertEqual(window.titleVisibility, .hidden)
            window.setContentSize(NSSize(width: 380, height: 300))
            await Task.yield()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(toolbar.visibleItems?.isEmpty ?? false)
            XCTAssertEqual(window.titleVisibility, .visible)
            XCTAssertEqual(toolbar.items.count, 1, "Retain the system title-bar selector.")
        }
    }

    func testPackagesWindowDoesNotAutomaticallyFocusSearchOnOpening() async throws {
        let autosaveKey = "NSWindow Frame FreshBrew.packages"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }
        let presenter = makeWindowPresenter()
        let controller = presenter.showInstalledPackages()
        let window = try XCTUnwrap(controller.window)
        defer {
            controller.windowFrameAutosaveName = ""
            controller.close()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === window)

        func searchField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Search packages" {
                return field
            }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(field))
        try await Task.sleep(for: .milliseconds(20))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)

        // Bringing an already-open window forward must preserve intentional editing.
        presenter.showInstalledPackages()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(window.firstResponder === editor)

        controller.close()
        presenter.showInstalledPackages()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === window)
    }

    func testPackageTabsRestoreAtTheSameWidthAfterClosingAndReopening() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Title-bar tab presentation requires macOS 26.")
        }
        let autosaveKey = "NSWindow Frame FreshBrew.packages"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }
        let presenter = makeWindowPresenter(skippedPackageCount: 99)
        let controller = presenter.showInstalledPackages()
        let window = try XCTUnwrap(controller.window)
        defer {
            controller.windowFrameAutosaveName = ""
            controller.close()
        }

        var collapsingWidth: Int?
        var restoringWidth: Int?
        for width in stride(from: 640, through: 380, by: -4) {
            window.setContentSize(NSSize(width: width, height: 320))
            try await Task.sleep(for: .milliseconds(20))
            if window.toolbar?.visibleItems?.isEmpty == true, collapsingWidth == nil {
                collapsingWidth = width
            }
        }
        controller.close()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(presenter.showInstalledPackages() === controller)
        try await Task.sleep(for: .milliseconds(20))
        for width in stride(from: 380, through: 640, by: 4) {
            window.setContentSize(NSSize(width: width, height: 320))
            try await Task.sleep(for: .milliseconds(20))
            if window.toolbar?.visibleItems?.isEmpty == false {
                restoringWidth = width
                break
            }
        }
        let collapsed = try XCTUnwrap(collapsingWidth)
        let restored = try XCTUnwrap(restoringWidth)
        XCTAssertLessThanOrEqual(restored - collapsed, 4,
                                 "The fallback title must not delay restoring tabs: collapsed at \(collapsed), restored at \(restored).")
    }

    private func makeWindowPresenter(skippedPackageCount: Int = 0) -> AppWindowPresenter {
        let defaults = InMemoryPreferencesStore()
        let preferences = FreshBrewPreferences(defaults: defaults)
        preferences.rememberedSkippedPackageIDs = Set(
            (0..<skippedPackageCount).map { "formula:package-\($0)" }
        )
        let model = MenuBarModel(
            homebrewService: HomebrewService(
                executableURL: URL(fileURLWithPath: "/usr/local/bin/brew"),
                runner: EmptyInventoryCommandRunner(),
                executableIsAvailable: { _ in true }
            ),
            preferences: preferences,
            historyStore: UpdateHistoryStore(defaults: defaults),
            packageHomepageStore: PackageHomepageStore(defaults: defaults)
        )
        return AppWindowPresenter(
            model: model,
            applicationUpdateCoordinator: ApplicationUpdateCoordinator(
                checker: GitHubApplicationUpdateService(installedVersion: "0.3.0"),
                preferences: preferences,
                notificationService: NoopApplicationUpdateNotificationService()
            )
        )
    }

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
