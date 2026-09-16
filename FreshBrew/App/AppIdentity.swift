import Foundation

enum AppIdentity {
    static let bundleName = configuredString(for: "CFBundleName")
        ?? Bundle.main.executableURL?.deletingPathExtension().lastPathComponent
        ?? ProcessInfo.processInfo.processName
    static let displayName = configuredString(for: "CFBundleDisplayName")
        ?? bundleName
    static let bundleIdentifier = Bundle.main.bundleIdentifier
        ?? bundleName

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
    }

    private static func configuredString(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
