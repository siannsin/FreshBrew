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
        packagesWindowState.selectedTab = tab
        return showWindow(
            id: .packages,
            title: "Packages",
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
    private let model: MenuBarModel
    private let windowState: PackagesWindowState
    private let tabs: [PackagesWindowState.Tab] = [.installed, .history, .skipped]
    private let overflowItem = NSMenuItem(title: "Packages", action: nil, keyEquivalent: "")
    private weak var observedToolbarItem: NSToolbarItem?
    private var overflowObservation: AnyCancellable?
    private var overflowMenuObservation: AnyCancellable?
    private var resizeObservation: AnyCancellable?
    private var lastTitleLayoutWidth: CGFloat?
    private var titleUpdateScheduled = false

    init(rootView: AnyView, model: MenuBarModel, windowState: PackagesWindowState) {
        self.model = model
        self.windowState = windowState
        super.init(rootView: rootView)

        resizeObservation = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow,
                      window === self.viewIfLoaded?.window else { return }
                self.scheduleWindowTitleUpdate()
            }

        let menu = NSMenu(title: "Packages")
        for (index, title) in ["Installed", "History", "Skipped"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectTab(_:)), keyEquivalent: "")
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
        lastTitleLayoutWidth = nil
        scheduleWindowTitleUpdate()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleWindowTitleUpdate()
        // This window's only toolbar item is the automatic TabView selector.
        // Do not resize or replace its view; only replace SwiftUI's overflow rendering.
        guard let toolbar = view.window?.toolbar, toolbar.items.count == 1,
              let item = toolbar.items.first else { return }
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
    }

    private func scheduleWindowTitleUpdate() {
        guard !titleUpdateScheduled else { return }
        titleUpdateScheduled = true
        // Native title changes can update SwiftUI's toolbar state; do them after its view update.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.titleUpdateScheduled = false }
            guard let window = self.viewIfLoaded?.window else { return }
            if self.lastTitleLayoutWidth != window.frame.width {
                self.lastTitleLayoutWidth = window.frame.width
                if window.toolbar != nil, window.titleVisibility != .hidden {
                    window.titleVisibility = .hidden
                    // Re-evaluate available space without the fallback title, outside view layout.
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                }
            }
            self.updateWindowTitle()
            self.updateTabDigitFont()
        }
    }

    private func updateTabDigitFont() {
        guard let rootView = view.window?.toolbar?.items.first?.view,
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

    private func updateWindowTitle() {
        guard let window = view.window else { return }
        let title: String
        switch windowState.selectedTab {
        case .installed: title = "Installed Packages"
        case .history: title = "Update History"
        case .skipped: title = "Skipped Packages"
        }
        if window.title != title { window.title = title }
        // Use the toolbar's actual presentation, not a hardcoded width threshold.
        let tabsAreVisible = window.toolbar?.visibleItems?.isEmpty == false
        let visibility: NSWindow.TitleVisibility = tabsAreVisible ? .hidden : .visible
        if window.titleVisibility != visibility { window.titleVisibility = visibility }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard tabs.indices.contains(menuItem.tag) else { return false }
        let tab = tabs[menuItem.tag]
        if tab == .skipped {
            menuItem.title = "Skipped (\(model.rememberedSkippedPackageIDs.count))"
        }
        menuItem.state = tab == windowState.selectedTab ? .on : .off
        return true
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        windowState.selectedTab = tabs[sender.tag]
    }
}
