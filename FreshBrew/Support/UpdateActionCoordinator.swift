import Foundation

@MainActor
final class UpdateActionCoordinator {
    private let model: MenuBarModel
    private let passwordPrompt: any AdminPasswordPrompting
    private let maximumPasswordAttempts: Int

    init(
        model: MenuBarModel,
        passwordPrompt: (any AdminPasswordPrompting)? = nil,
        maximumPasswordAttempts: Int = 3
    ) {
        self.model = model
        self.passwordPrompt = passwordPrompt ?? AdminAuthorizationPrompt()
        self.maximumPasswordAttempts = maximumPasswordAttempts
    }

    func updateAll() async {
        _ = await model.updateAll()
        await retryWithAdministratorAccessIfNeeded()
    }

    func update(_ package: HomebrewPackage) async {
        _ = await model.update(package: package)
        await retryWithAdministratorAccessIfNeeded()
    }

    private func retryWithAdministratorAccessIfNeeded() async {
        var attempt = 0
        while model.administratorAccessRequired, attempt < maximumPasswordAttempts {
            guard let password = await passwordPrompt.requestPassword() else { return }
            attempt += 1
            _ = await model.retryLastUpdate(administratorPassword: password)
        }
    }
}
