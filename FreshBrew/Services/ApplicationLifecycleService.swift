import AppKit
import Foundation

@MainActor
protocol ApplicationLifecycleServicing {
    func reopenApplicationsIfNeeded(bundleIdentifiers: Set<String>)
}

@MainActor
final class ApplicationLifecycleService: ApplicationLifecycleServicing {
    private let isApplicationRunning: (String) -> Bool
    private let applicationURL: (String) -> URL?
    private let openApplication: (URL) -> Void

    init(
        isApplicationRunning: @escaping (String) -> Bool = { bundleIdentifier in
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        },
        applicationURL: @escaping (String) -> URL? = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        },
        openApplication: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    ) {
        self.isApplicationRunning = isApplicationRunning
        self.applicationURL = applicationURL
        self.openApplication = openApplication
    }

    func reopenApplicationsIfNeeded(bundleIdentifiers: Set<String>) {
        for bundleIdentifier in bundleIdentifiers.sorted() {
            guard !isApplicationRunning(bundleIdentifier),
                  let url = applicationURL(bundleIdentifier) else {
                continue
            }
            openApplication(url)
        }
    }
}
