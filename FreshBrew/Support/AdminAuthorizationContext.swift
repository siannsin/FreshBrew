import Foundation

struct AdminAuthorizationContext: Equatable, Sendable {
    static let helperName = "FreshBrewAskpass"

    let askpassExecutableURL: URL

    var environment: [String: String] {
        environment(packageContextFileURL: nil)
    }

    func environment(packageContextFileURL: URL?) -> [String: String] {
        var environment = ["SUDO_ASKPASS": askpassExecutableURL.path]
        if let packageContextFileURL {
            environment[AskpassPackageContextSession.environmentKey] = packageContextFileURL.path
        }
        return environment
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
