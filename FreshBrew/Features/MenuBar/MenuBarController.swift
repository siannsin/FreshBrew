import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: MenuBarModel
    private let updateCoordinator: UpdateActionCoordinator
    private let windowPresenter: AppWindowPresenter
    private let packageHomepageService: any PackageHomepageOpening
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var statusIconAnimator: StatusIconAnimator?
    private var modelChangeCancellable: AnyCancellable?
    private var isMenuOpen = false
    private var isModelRefreshScheduled = false

    init(
        model: MenuBarModel,
        updateCoordinator: UpdateActionCoordinator,
        windowPresenter: AppWindowPresenter,
        packageHomepageService: (any PackageHomepageOpening)? = nil
    ) {
        self.model = model
        self.updateCoordinator = updateCoordinator
        self.windowPresenter = windowPresenter
        self.packageHomepageService = packageHomepageService ?? PackageHomepageService()
        statusItem = NSStatusBar.system.statusItem(withLength: 20)
        super.init()

        if let button = statusItem.button {
            statusIconAnimator = StatusIconAnimator(button: button)
            statusIconAnimator?.setState(
                activity: model.activity,
                hasAvailableUpdates: !model.visiblePackages.isEmpty
            )
            button.toolTip = AppIdentity.displayName
        }

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        modelChangeCancellable = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.scheduleModelRefresh()
            }
        }
    }

    func stop() {
        modelChangeCancellable = nil
        statusIconAnimator?.stop()
        statusIconAnimator = nil
        isMenuOpen = false
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func scheduleModelRefresh() {
        guard !isModelRefreshScheduled else { return }
        isModelRefreshScheduled = true

        // ObservableObject announces changes before its published values are
        // assigned. Moving to the next main-queue turn also coalesces related
        // changes from one operation into one icon and menu refresh.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isModelRefreshScheduled = false
            self.statusIconAnimator?.setState(
                activity: self.model.activity,
                hasAvailableUpdates: !self.model.visiblePackages.isEmpty
            )
            if self.isMenuOpen {
                self.rebuildMenu()
                self.menu.update()
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        addInformationalItem(headerTitle)

        if !model.visiblePackages.isEmpty {
            addAvailableUpdatesMenu()
        }

        menu.addItem(.separator())

        if !model.visiblePackages.isEmpty {
            addActionItem(
                model.updateAllLabel,
                action: #selector(updateAll),
                isEnabled: !model.isRunning
            )
        }

        addActionItem(
            model.checkUpdatesLabel,
            action: #selector(checkUpdates),
            isEnabled: !model.isRunning
        )

        menu.addItem(.separator())

        if let latestUpdate = model.latestUpdate {
            addLastUpdateMenu(latestUpdate)
        }

        addActionItem("Update History", action: #selector(showUpdateHistory))
        addActionItem("Skipped Packages", action: #selector(showSkippedPackages))

        menu.addItem(.separator())
        addSettingsMenu()
        addMaintenanceMenu()
        addActionItem("About FreshBrew", action: #selector(showAbout))
        addActionItem("Quit FreshBrew", action: #selector(quit))
    }

    private var headerTitle: String {
        if model.isRunning || model.lastErrorMessage != nil {
            return model.statusMessage
        }
        if let packageHomepageErrorMessage = model.packageHomepageErrorMessage {
            return packageHomepageErrorMessage
        }
        if let lastCheckDate = model.lastSuccessfulHomebrewCheckDate {
            return "Last checked: \(lastCheckDate.formatted(date: .omitted, time: .shortened))"
        }
        return "FreshBrew is ready"
    }

    private func addAvailableUpdatesMenu() {
        let item = NSMenuItem(
            title: "Available Updates (\(model.visiblePackages.count))",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: item.title)

        for package in model.visiblePackages {
            submenu.addItem(Self.makeAvailablePackageMenuItem(
                package: package,
                target: self,
                openPageAction: #selector(openAvailablePackageHomepage(_:)),
                updateAction: #selector(updatePackage(_:)),
                skipOnceAction: #selector(skipPackageOnce(_:)),
                alwaysSkipAction: #selector(alwaysSkipPackage(_:)),
                updatesEnabled: !model.isRunning
            ))
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func addLastUpdateMenu(_ update: UpdateHistoryEntry) {
        let item = NSMenuItem(title: "Last Update", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Last Update")
        let formulae = update.packages.filter { $0.kind == .formula }
        let casks = update.packages.filter { $0.kind == .cask }

        if !formulae.isEmpty {
            addLastUpdateSection("Formulae", packages: formulae, to: submenu)
        }

        if !formulae.isEmpty, !casks.isEmpty {
            submenu.addItem(.separator())
        }

        if !casks.isEmpty {
            addLastUpdateSection("Casks", packages: casks, to: submenu)
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func addLastUpdateSection(
        _ title: String,
        packages: [UpdatedPackage],
        to menu: NSMenu
    ) {
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        for package in packages {
            let version = HomebrewVersionDisplay.compact(
                package.installedVersion,
                kind: package.kind
            )
            menu.addItem(Self.makeLastUpdatePackageItem(
                package: package,
                title: "\(package.name) \(version)",
                target: self,
                openPageAction: #selector(openUpdatedPackageHomepage(_:))
            ))
        }
    }

    static func makeAvailablePackageMenuItem(
        package: HomebrewPackage,
        target: AnyObject?,
        openPageAction: Selector,
        updateAction: Selector,
        skipOnceAction: Selector,
        alwaysSkipAction: Selector,
        updatesEnabled: Bool
    ) -> NSMenuItem {
        let packageItem = NSMenuItem(title: package.name, action: nil, keyEquivalent: "")
        let packageMenu = NSMenu(title: package.name)

        let versionItem = NSMenuItem(
            title: HomebrewVersionDisplay.compactTransition(for: package),
            action: openPageAction,
            keyEquivalent: ""
        )
        versionItem.target = target
        versionItem.representedObject = package
        versionItem.isEnabled = true
        packageMenu.addItem(versionItem)
        packageMenu.addItem(.separator())

        let actionDetails: [(String, Selector)] = [
            ("Update", updateAction),
            ("Skip This Time", skipOnceAction),
            ("Always Skip", alwaysSkipAction)
        ]
        for (title, action) in actionDetails {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = package
            item.isEnabled = updatesEnabled
            packageMenu.addItem(item)
        }

        packageItem.submenu = packageMenu
        return packageItem
    }

    static func makeLastUpdatePackageItem(
        package: UpdatedPackage,
        title: String,
        target: AnyObject?,
        openPageAction: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: openPageAction, keyEquivalent: "")
        item.target = target
        item.representedObject = package
        item.isEnabled = true
        return item
    }

    private func addSettingsMenu() {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Settings")

        let greedyItem = actionItem(
            "Greedy Mode",
            action: #selector(toggleGreedyMode),
            isEnabled: !model.isRunning
        )
        greedyItem.state = model.greedyModeEnabled ? .on : .off
        submenu.addItem(greedyItem)

        let modeItem = NSMenuItem(title: "Check Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu(title: "Check Mode")
        let afterUnlockItem = actionItem("After Unlock", action: #selector(selectAfterUnlockMode))
        afterUnlockItem.state = model.automaticCheckMode == .afterUnlock ? .on : .off
        modeMenu.addItem(afterUnlockItem)
        let periodicItem = actionItem("Periodic", action: #selector(selectPeriodicMode))
        periodicItem.state = model.automaticCheckMode == .periodic ? .on : .off
        modeMenu.addItem(periodicItem)
        modeItem.submenu = modeMenu
        submenu.addItem(modeItem)

        if model.automaticCheckMode == .periodic {
            let intervalItem = NSMenuItem(title: "Check Interval", action: nil, keyEquivalent: "")
            let intervalMenu = NSMenu(title: "Check Interval")
            for option in PeriodicIntervalOption.all {
                let optionItem = actionItem(
                    option.title,
                    action: #selector(selectPeriodicInterval(_:)),
                    representedObject: option.seconds
                )
                optionItem.state = model.periodicCheckInterval == option.seconds ? .on : .off
                intervalMenu.addItem(optionItem)
            }
            intervalItem.submenu = intervalMenu
            submenu.addItem(intervalItem)
        }

        submenu.addItem(.separator())

        let cleanupItem = actionItem("Auto Cleanup", action: #selector(toggleAutoCleanup))
        cleanupItem.state = model.autoCleanupEnabled ? .on : .off
        submenu.addItem(cleanupItem)

        let loginItem = actionItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
        loginItem.state = model.launchAtLoginEnabled ? .on : .off
        submenu.addItem(loginItem)

        item.submenu = submenu
        menu.addItem(item)
    }

    private func addMaintenanceMenu() {
        let item = NSMenuItem(title: "Maintenance", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Maintenance")
        submenu.addItem(actionItem(
            "Cleanup",
            action: #selector(cleanup),
            isEnabled: !model.isRunning
        ))
        submenu.addItem(actionItem(
            "Deep Cleanup",
            action: #selector(deepCleanup),
            isEnabled: !model.isRunning
        ))
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addInformationalItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addActionItem(
        _ title: String,
        action: Selector,
        isEnabled: Bool = true
    ) {
        menu.addItem(actionItem(title, action: action, isEnabled: isEnabled))
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        representedObject: Any? = nil,
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.isEnabled = isEnabled
        return item
    }

    @objc private func checkUpdates() {
        Task { _ = await model.checkUpdates() }
    }

    @objc private func updateAll() {
        Task { await updateCoordinator.updateAll() }
    }

    @objc private func updatePackage(_ sender: NSMenuItem) {
        guard let package = sender.representedObject as? HomebrewPackage else { return }
        Task { await updateCoordinator.update(package) }
    }

    @objc private func skipPackageOnce(_ sender: NSMenuItem) {
        guard let package = sender.representedObject as? HomebrewPackage else { return }
        model.skip(package, remember: false)
    }

    @objc private func alwaysSkipPackage(_ sender: NSMenuItem) {
        guard let package = sender.representedObject as? HomebrewPackage else { return }
        model.skip(package, remember: true)
    }

    @objc private func openAvailablePackageHomepage(_ sender: NSMenuItem) {
        guard let package = sender.representedObject as? HomebrewPackage else { return }
        openPackageHomepage(
            name: package.name,
            kind: package.kind,
            homepageURL: package.homepageURL
        )
    }

    @objc private func openUpdatedPackageHomepage(_ sender: NSMenuItem) {
        guard let package = sender.representedObject as? UpdatedPackage else { return }
        openPackageHomepage(
            name: package.name,
            kind: package.kind,
            homepageURL: package.homepageURL
        )
    }

    private func openPackageHomepage(
        name: String,
        kind: HomebrewPackageKind,
        homepageURL: URL?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await packageHomepageService.openPage(
                    packageName: name,
                    kind: kind,
                    homepageURL: homepageURL
                )
                if !opened {
                    model.reportPackageHomepageOpenFailure()
                } else {
                    model.reportPackageHomepageOpened()
                }
            } catch {
                model.reportPackageHomepageOpenFailure()
            }
        }
    }

    @objc private func toggleGreedyMode() {
        model.greedyModeEnabled.toggle()
    }

    @objc private func selectAfterUnlockMode() {
        model.automaticCheckMode = .afterUnlock
    }

    @objc private func selectPeriodicMode() {
        model.automaticCheckMode = .periodic
    }

    @objc private func selectPeriodicInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        model.setPeriodicCheckInterval(interval)
    }

    @objc private func toggleAutoCleanup() {
        model.autoCleanupEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        model.setLaunchAtLoginEnabled(!model.launchAtLoginEnabled)
    }

    @objc private func cleanup() {
        Task { _ = await model.cleanup(deep: false) }
    }

    @objc private func deepCleanup() {
        Task { _ = await model.cleanup(deep: true) }
    }

    @objc private func showUpdateHistory() {
        windowPresenter.showUpdateHistory()
    }

    @objc private func showSkippedPackages() {
        windowPresenter.showSkippedPackages()
    }

    @objc private func showAbout() {
        windowPresenter.showAbout()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct PeriodicIntervalOption {
    static let all = [
        PeriodicIntervalOption(title: "1 Hour", seconds: 3_600),
        PeriodicIntervalOption(title: "2 Hours", seconds: 7_200),
        PeriodicIntervalOption(title: "4 Hours", seconds: 14_400),
        PeriodicIntervalOption(title: "8 Hours", seconds: 28_800),
        PeriodicIntervalOption(title: "12 Hours", seconds: 43_200),
        PeriodicIntervalOption(title: "24 Hours", seconds: 86_400)
    ]

    let title: String
    let seconds: TimeInterval
}
