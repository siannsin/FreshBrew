import AppKit
import SwiftUI

@MainActor
final class AppWindowPresenter {
    private enum WindowID: String {
        case updateHistory
        case skippedPackages
        case about
    }

    private let model: MenuBarModel
    private var windowControllers: [WindowID: NSWindowController] = [:]

    init(model: MenuBarModel) {
        self.model = model
    }

    func showUpdateHistory() {
        showWindow(
            id: .updateHistory,
            title: "Update History",
            contentSize: NSSize(width: 400, height: 320),
            minimumSize: NSSize(width: 380, height: 300),
            isResizable: true,
            content: AnyView(HistoryView(model: model))
        )
    }

    func showSkippedPackages() {
        showWindow(
            id: .skippedPackages,
            title: "Skipped Packages",
            contentSize: NSSize(width: 400, height: 320),
            minimumSize: NSSize(width: 380, height: 300),
            isResizable: true,
            content: AnyView(SkippedPackagesView(model: model))
        )
    }

    func showAbout() {
        showWindow(
            id: .about,
            title: "About FreshBrew",
            contentSize: NSSize(width: 340, height: 230),
            minimumSize: NSSize(width: 340, height: 230),
            isResizable: false,
            content: AnyView(AboutView())
        )
    }

    private func showWindow(
        id: WindowID,
        title: String,
        contentSize: NSSize,
        minimumSize: NSSize,
        isResizable: Bool,
        content: AnyView
    ) {
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
            let hostingController = NSHostingController(rootView: content)
            if isResizable {
                // Keep SwiftUI's minimum-size contribution without allowing a
                // compact empty state to become the window's maximum size.
                hostingController.sizingOptions = [.minSize]
            }
            window.title = title
            window.contentMinSize = minimumSize
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            if isResizable {
                window.setFrameAutosaveName("FreshBrew.\(id.rawValue)")
            }
            window.center()

            controller = NSWindowController(window: window)
            windowControllers[id] = controller
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
