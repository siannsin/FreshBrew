import AppKit
import Foundation

@MainActor
final class SessionUnlockMonitor {
    private var workspaceObserver: NSObjectProtocol?
    private var distributedObserver: NSObjectProtocol?

    func start(onUnlock: @escaping @MainActor () -> Void) {
        stop()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onUnlock() }
        }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onUnlock() }
        }
    }

    func stop() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        workspaceObserver = nil
        distributedObserver = nil
    }
}
