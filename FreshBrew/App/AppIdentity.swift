import Foundation

enum AppIdentity {
    static let displayName = "FreshBrew"
    static let bundleIdentifier = "net.siann.freshbrew"

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

}
