import Foundation

struct AdminAuthorizationContext: Equatable, Sendable {
    static let helperName = "FreshBrewAskpass"

    let askpassExecutableURL: URL

    var environment: [String: String] {
        ["SUDO_ASKPASS": askpassExecutableURL.path]
    }

    static func bundled(
        appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> AdminAuthorizationContext? {
        let helperURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName)
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            return nil
        }
        return AdminAuthorizationContext(askpassExecutableURL: helperURL)
    }
}
