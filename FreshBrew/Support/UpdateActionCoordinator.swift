import Foundation

@MainActor
final class UpdateActionCoordinator {
    private let model: MenuBarModel

    init(model: MenuBarModel) {
        self.model = model
    }

    func updateAll() async {
        _ = await model.updateAll()
    }

    func update(_ package: HomebrewPackage) async {
        _ = await model.update(package: package)
    }
}
