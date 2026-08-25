import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model: MenuBarModel
    let updateCoordinator: UpdateActionCoordinator
    let applicationUpdateCoordinator: ApplicationUpdateCoordinator

    private let notificationService: NotificationService
    private let unlockMonitor = SessionUnlockMonitor()
    private let notificationRouter: NotificationActionRouter
    private let windowPresenter: AppWindowPresenter
    private let packageHomepageService: PackageHomepageService
    private let relaunchService: ApplicationRelaunchService
    private var menuBarController: MenuBarController?

    override init() {
        let notificationService = NotificationService()
        let preferences = FreshBrewPreferences()
        let homebrewService = HomebrewService()
        let packageHomepageStore = PackageHomepageStore()
        let packageHomepageService = PackageHomepageService(
            homepageResolver: homebrewService,
            store: packageHomepageStore
        )
        let model = MenuBarModel(
            homebrewService: homebrewService,
            preferences: preferences,
            packageHomepageStore: packageHomepageStore,
            notificationService: notificationService
        )
        let updateCoordinator = UpdateActionCoordinator(model: model)
        let relaunchService = ApplicationRelaunchService()
        let applicationUpdateCoordinator = ApplicationUpdateCoordinator(
            checker: GitHubApplicationUpdateService(
                installedVersion: AppIdentity.marketingVersion
            ),
            preferences: preferences,
            notificationService: notificationService
        )
        self.notificationService = notificationService
        self.model = model
        self.updateCoordinator = updateCoordinator
        self.applicationUpdateCoordinator = applicationUpdateCoordinator
        self.packageHomepageService = packageHomepageService
        self.relaunchService = relaunchService
        windowPresenter = AppWindowPresenter(
            model: model,
            applicationUpdateCoordinator: applicationUpdateCoordinator,
            packageHomepageService: packageHomepageService
        )
        notificationRouter = NotificationActionRouter(
            updateAll: {
                NSApplication.shared.activate(ignoringOtherApps: true)
                await updateCoordinator.updateAll()
            },
            viewRelease: { releasePageURL in
                applicationUpdateCoordinator.openReleasePage(from: releasePageURL)
            },
            restartApplication: {
                do {
                    try relaunchService.relaunch()
                } catch {
                    model.reportRestartFailure(
                        (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    )
                }
            }
        )
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
            windowPresenter: windowPresenter,
            packageHomepageService: packageHomepageService,
            restartApplication: { [weak self] in
                self?.restartApplication()
            }
        )
        Task { await notificationService.requestAuthorization() }
        model.startAutomaticChecks()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            applicationUpdateCoordinator.startBackgroundChecks()
        }
        unlockMonitor.start { [weak model] in
            model?.scheduleCheckAfterUnlock()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
        menuBarController = nil
        unlockMonitor.stop()
        model.stopAutomaticChecks()
        applicationUpdateCoordinator.stopBackgroundChecks()
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
        let releasePageURL = response.notification.request.content.userInfo[
            NotificationService.releasePageURLUserInfoKey
        ] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            if let self {
                _ = await notificationRouter.handle(
                    actionIdentifier: actionIdentifier,
                    releasePageURL: releasePageURL
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

    private func restartApplication() {
        do {
            try relaunchService.relaunch()
        } catch {
            model.reportRestartFailure(
                (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }
}
