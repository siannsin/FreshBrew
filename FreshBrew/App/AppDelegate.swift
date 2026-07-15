import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: MenuBarModel
    let updateCoordinator: UpdateActionCoordinator

    private let notificationService: NotificationService
    private let unlockMonitor = SessionUnlockMonitor()
    private let notificationRouter: NotificationActionRouter
    private let windowPresenter: AppWindowPresenter
    private var menuBarController: MenuBarController?

    override init() {
        let notificationService = NotificationService()
        let model = MenuBarModel(notificationService: notificationService)
        let updateCoordinator = UpdateActionCoordinator(model: model)
        self.notificationService = notificationService
        self.model = model
        self.updateCoordinator = updateCoordinator
        windowPresenter = AppWindowPresenter(model: model)
        notificationRouter = NotificationActionRouter {
            NSApplication.shared.activate(ignoringOtherApps: true)
            await updateCoordinator.updateAll()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if shouldTerminateDuplicateInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        UNUserNotificationCenter.current().delegate = self
        menuBarController = MenuBarController(
            model: model,
            updateCoordinator: updateCoordinator,
            windowPresenter: windowPresenter
        )
        Task { await notificationService.requestAuthorization() }
        model.startAutomaticChecks()
        unlockMonitor.start { [weak model] in
            model?.scheduleCheckAfterUnlock()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
        menuBarController = nil
        unlockMonitor.stop()
        model.stopAutomaticChecks()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        completionHandler()
        Task { @MainActor [weak self] in
            if let self {
                _ = await notificationRouter.handle(
                    actionIdentifier: actionIdentifier
                )
            }
        }
    }

    private func shouldTerminateDuplicateInstance() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        let identifiers = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier)
        return SingleInstanceGuard.shouldTerminateNewInstance(
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            runningProcessIdentifiers: identifiers
        )
    }
}
