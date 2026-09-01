import AppKit
import Combine
import SwiftUI

@MainActor
final class AppWindowPresenter {
    private enum WindowID: String {
        case packages
        case about
    }

    private let model: MenuBarModel
    private let applicationUpdateCoordinator: ApplicationUpdateCoordinator
    private let packageHomepageService: any PackageHomepageOpening
    private var windowControllers: [WindowID: NSWindowController] = [:]
    let packagesWindowState = PackagesWindowState()

    init(
        model: MenuBarModel,
        applicationUpdateCoordinator: ApplicationUpdateCoordinator,
        packageHomepageService: any PackageHomepageOpening = PackageHomepageService()
    ) {
        self.model = model
        self.applicationUpdateCoordinator = applicationUpdateCoordinator
        self.packageHomepageService = packageHomepageService
    }

    @discardableResult
    func showInstalledPackages() -> NSWindowController {
        showPackages(tab: .installed)
    }

    @discardableResult
    func showUpdateHistory() -> NSWindowController {
        showPackages(tab: .history)
    }

    @discardableResult
    func showSkippedPackages() -> NSWindowController {
        showPackages(tab: .skipped)
    }

    private func showPackages(tab: PackagesWindowState.Tab) -> NSWindowController {
        if packagesWindowState.selectedTab != tab {
            packagesWindowState.selectedTab = tab
        }
        let controller = showWindow(
            id: .packages,
            title: tab.windowTitle,
            contentSize: NSSize(width: 400, height: 320),
            minimumSize: NSSize(width: 380, height: 300),
            isResizable: true,
            content: AnyView(PackagesView(
                model: model,
                windowState: packagesWindowState,
                openPackageHomepage: { [weak self] name, kind, url in
                    self?.openPackageHomepage(name: name, kind: kind, homepageURL: url)
                }
            ))
        )
        controller.window?.title = tab.windowTitle
        return controller
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
                opened
                    ? model.reportPackageHomepageOpened()
                    : model.reportPackageHomepageOpenFailure()
            } catch {
                model.reportPackageHomepageOpenFailure()
            }
        }
    }

    @discardableResult
    func showAbout() -> NSWindowController {
        showWindow(
            id: .about,
            title: "About FreshBrew",
            contentSize: NSSize(width: 340, height: 310),
            minimumSize: NSSize(width: 340, height: 310),
            isResizable: false,
            content: AnyView(AboutView(
                applicationUpdateCoordinator: applicationUpdateCoordinator
            ))
        )
    }

    private func showWindow(
        id: WindowID,
        title: String,
        contentSize: NSSize,
        minimumSize: NSSize,
        isResizable: Bool,
        content: AnyView
    ) -> NSWindowController {
        let controller: NSWindowController
        if let existingController = windowControllers[id] {
            controller = existingController
        } else {
            var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if isResizable {
                styleMask.insert(.resizable)
            }

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            let hostingController: NSHostingController<AnyView>
            if id == .packages {
                hostingController = PackagesHostingController(
                    rootView: content, model: model, windowState: packagesWindowState
                )
            } else {
                hostingController = NSHostingController(rootView: content)
            }
            if isResizable {
                // Use the root view's width limits while keeping height flexible.
                hostingController.sizingOptions = [.minSize, .maxSize]
            }
            window.title = title
            window.contentMinSize = minimumSize
            window.contentViewController = hostingController
            window.setContentSize(contentSize)
            window.isReleasedWhenClosed = false
            window.center()

            controller = NSWindowController(window: window)
            if isResizable {
                let autosaveName = "FreshBrew.\(id.rawValue)"
                controller.windowFrameAutosaveName = autosaveName
                controller.shouldCascadeWindows = false
                window.setFrameUsingName(autosaveName)
            }
            windowControllers[id] = controller
        }

        let wasVisible = controller.window?.isVisible == true
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if id == .packages, !wasVisible {
            controller.window?.makeFirstResponder(nil)
        }
        return controller
    }
}

/// Keeps the native title-bar tabs, supplying plain menu items for toolbar overflow.
@MainActor
private final class PackagesHostingController: NSHostingController<AnyView>, NSMenuItemValidation {
    private static let titleSettleDelay: TimeInterval = 0.01

    private let model: MenuBarModel
    private let windowState: PackagesWindowState
    private let tabs = PackagesWindowState.Tab.allCases
    private let overflowItem = NSMenuItem(title: "Packages", action: nil, keyEquivalent: "")
    private weak var observedToolbarItem: NSToolbarItem?
    private var selectionObservation: AnyCancellable?
    private var overflowObservation: AnyCancellable?
    private var overflowMenuObservation: AnyCancellable?
    private var resizeObservation: AnyCancellable?
    private var resizeStartObservation: AnyCancellable?
    private var resizeEndObservation: AnyCancellable?
    private var titleUpdateWorkItem: DispatchWorkItem?
    private var resizeTitleUpdateWorkItem: DispatchWorkItem?

    init(rootView: AnyView, model: MenuBarModel, windowState: PackagesWindowState) {
        self.model = model
        self.windowState = windowState
        super.init(rootView: rootView)

        selectionObservation = windowState.$selectedTab
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.viewIfLoaded?.window?.isVisible == true else { return }
                self.scheduleWindowTitleUpdate()
            }

        resizeStartObservation = NotificationCenter.default.publisher(
            for: NSWindow.willStartLiveResizeNotification
        )
        .sink { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  window === self.viewIfLoaded?.window else { return }
            self.titleUpdateWorkItem?.cancel()
            self.titleUpdateWorkItem = nil
            self.resizeTitleUpdateWorkItem?.cancel()
            self.resizeTitleUpdateWorkItem = nil
            window.titleVisibility = .hidden
        }

        resizeObservation = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow,
                      window === self.viewIfLoaded?.window else { return }
                self.titleUpdateWorkItem?.cancel()
                self.titleUpdateWorkItem = nil
                // The fallback title must not consume space while AppKit decides
                // whether the native tab selector fits.
                if window.titleVisibility != .hidden {
                    window.titleVisibility = .hidden
                }
                guard !window.inLiveResize else { return }
                self.scheduleWindowTitleUpdateAfterResize()
            }

        resizeEndObservation = NotificationCenter.default.publisher(
            for: NSWindow.didEndLiveResizeNotification
        )
        .sink { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  window === self.viewIfLoaded?.window else { return }
            self.resizeTitleUpdateWorkItem?.cancel()
            self.resizeTitleUpdateWorkItem = nil
            self.scheduleWindowTitleUpdate()
        }

        let menu = NSMenu(title: "Packages")
        for (index, tab) in tabs.enumerated() {
            let item = NSMenuItem(
                title: tab.title,
                action: #selector(selectTab(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        overflowItem.submenu = menu
        overflowItem.identifier = NSUserInterfaceItemIdentifier("FreshBrew.packageTabsOverflow")
        // Flatten only our entry while AppKit constructs the overflow menu.
        overflowMenuObservation = NotificationCenter.default.publisher(for: NSMenu.didAddItemNotification)
            .sink { [weak self] notification in
                guard let self,
                      let menu = notification.object as? NSMenu,
                      let index = notification.userInfo?["NSMenuItemIndex"] as? Int,
                      menu.items.indices.contains(index),
                      menu.items[index].identifier == self.overflowItem.identifier,
                      let tabs = menu.items[index].submenu?.items else { return }
                menu.removeItem(at: index)
                for (offset, tab) in tabs.enumerated() {
                    guard let copy = tab.copy() as? NSMenuItem else { continue }
                    menu.insertItem(copy, at: index + offset)
                }
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.titleVisibility = .hidden
        scheduleWindowTitleUpdateAfterResize()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if resizeTitleUpdateWorkItem == nil {
            scheduleWindowTitleUpdate()
        }
        // Find the automatic TabView selector by its stable tab labels. Do not
        // resize or replace its view; only replace SwiftUI's overflow rendering.
        guard let toolbar = view.window?.toolbar,
              let item = packageTabItem(in: toolbar) else { return }
        if observedToolbarItem !== item {
            observedToolbarItem = item
            // SwiftUI can replace the overflow menu without laying out the content again.
            overflowObservation = item.publisher(for: \.menuFormRepresentation, options: [.new])
                .sink { [weak self, weak item] _ in
                    guard let self, let item, item.menuFormRepresentation !== self.overflowItem else { return }
                    item.menuFormRepresentation = self.overflowItem
                }
        }
        if item.menuFormRepresentation !== overflowItem {
            item.menuFormRepresentation = overflowItem
        }
        updateTabDigitFont()
    }

    private func scheduleWindowTitleUpdate() {
        guard titleUpdateWorkItem == nil else { return }
        // Native title changes can update SwiftUI's toolbar state; do them after its view update.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.titleUpdateWorkItem = nil
            guard self.viewIfLoaded?.window != nil else { return }
            self.updateWindowTitle()
            self.updateTabDigitFont()
        }
        titleUpdateWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func scheduleWindowTitleUpdateAfterResize() {
        resizeTitleUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeTitleUpdateWorkItem = nil
            self.scheduleWindowTitleUpdate()
        }
        resizeTitleUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.titleSettleDelay,
            execute: workItem
        )
    }

    private func updateTabDigitFont() {
        guard let toolbar = view.window?.toolbar,
              let rootView = packageTabItem(in: toolbar)?.view,
              let control = segmentedControl(in: rootView),
              let currentFont = control.font else { return }
        let tabularFont = NSFont.monospacedDigitSystemFont(
            ofSize: currentFont.pointSize,
            weight: .regular
        )
        guard currentFont.fontName != tabularFont.fontName else { return }
        control.font = tabularFont
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.segmentedControl(in: $0) }.first
    }

    private func packageTabItem(in toolbar: NSToolbar) -> NSToolbarItem? {
        if let observedToolbarItem, toolbar.items.contains(where: { $0 === observedToolbarItem }) {
            return observedToolbarItem
        }
        return toolbar.items.first { item in
            guard let itemView = item.view,
                  let control = segmentedControl(in: itemView),
                  control.segmentCount == tabs.count else { return false }
            return control.label(forSegment: 0) == PackagesWindowState.Tab.installed.title
                && control.label(forSegment: 1) == PackagesWindowState.Tab.history.title
        }
    }

    private func updateWindowTitle() {
        guard let window = view.window else { return }
        let title = windowState.selectedTab.windowTitle
        if window.title != title { window.title = title }
        guard !window.inLiveResize else {
            window.titleVisibility = .hidden
            return
        }
        // Use the selector item's actual AppKit state, not a hardcoded width threshold.
        let tabsAreVisible = window.toolbar
            .flatMap { packageTabItem(in: $0) }?
            .isVisible == true
        let visibility: NSWindow.TitleVisibility = tabsAreVisible ? .hidden : .visible
        if window.titleVisibility != visibility { window.titleVisibility = visibility }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard tabs.indices.contains(menuItem.tag) else { return false }
        let tab = tabs[menuItem.tag]
        if tab == .skipped {
            menuItem.title = tab.title(
                skippedPackageCount: model.rememberedSkippedPackageIDs.count
            )
        }
        menuItem.state = tab == windowState.selectedTab ? .on : .off
        return true
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        windowState.selectedTab = tabs[sender.tag]
    }
}
