import Foundation

enum AppIdentity {
    static let displayName = "FreshBrew"
    static let bundleIdentifier = "net.siann.freshbrew"

    static var bundleName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? displayName
    }

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
    }

}
