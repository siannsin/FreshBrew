import Foundation

protocol PreferencesStoring: AnyObject {
    func register(defaults registrationDictionary: [String: Any])
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func data(forKey defaultName: String) -> Data?
    func bool(forKey defaultName: String) -> Bool
    func double(forKey defaultName: String) -> Double
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferencesStoring {}

final class FreshBrewPreferences: @unchecked Sendable {
    private enum Key {
        static let greedyModeEnabled = "greedyModeEnabled"
        static let automaticCheckMode = "automaticCheckMode"
        static let periodicCheckInterval = "periodicCheckInterval"
        static let autoCleanupEnabled = "autoCleanupEnabled"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
        static let rememberedSkippedPackageIDs = "rememberedSkippedPackageIDs"
        static let lastHomebrewCheckDate = "lastHomebrewCheckDate"
    }

    private let defaults: any PreferencesStoring
    private let lock = NSLock()

    init(defaults: any PreferencesStoring = UserDefaults.standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.greedyModeEnabled: false,
            Key.automaticCheckMode: AutomaticCheckMode.afterUnlock.rawValue,
            Key.periodicCheckInterval: 14_400,
            Key.autoCleanupEnabled: false,
            Key.launchAtLoginEnabled: false,
            Key.rememberedSkippedPackageIDs: [String]()
        ])
    }

    var greedyModeEnabled: Bool {
        get { read { $0.bool(forKey: Key.greedyModeEnabled) } }
        set { write { $0.set(newValue, forKey: Key.greedyModeEnabled) } }
    }

    var automaticCheckMode: AutomaticCheckMode {
        get {
            read {
                AutomaticCheckMode(rawValue: $0.string(forKey: Key.automaticCheckMode) ?? "")
                    ?? .afterUnlock
            }
        }
        set { write { $0.set(newValue.rawValue, forKey: Key.automaticCheckMode) } }
    }

    var periodicCheckInterval: TimeInterval {
        get { read { $0.double(forKey: Key.periodicCheckInterval) } }
        set { write { $0.set(newValue, forKey: Key.periodicCheckInterval) } }
    }

    var autoCleanupEnabled: Bool {
        get { read { $0.bool(forKey: Key.autoCleanupEnabled) } }
        set { write { $0.set(newValue, forKey: Key.autoCleanupEnabled) } }
    }

    var launchAtLoginEnabled: Bool {
        get { read { $0.bool(forKey: Key.launchAtLoginEnabled) } }
        set { write { $0.set(newValue, forKey: Key.launchAtLoginEnabled) } }
    }

    var rememberedSkippedPackageIDs: Set<String> {
        get { read { Set($0.stringArray(forKey: Key.rememberedSkippedPackageIDs) ?? []) } }
        set { write { $0.set(newValue.sorted(), forKey: Key.rememberedSkippedPackageIDs) } }
    }

    var lastHomebrewCheckDate: Date? {
        get { read { $0.object(forKey: Key.lastHomebrewCheckDate) as? Date } }
        set { write { $0.set(newValue, forKey: Key.lastHomebrewCheckDate) } }
    }

    private func read<T>(_ operation: (any PreferencesStoring) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation(defaults)
    }

    private func write(_ operation: (any PreferencesStoring) -> Void) {
        lock.lock()
        operation(defaults)
        lock.unlock()
    }
}
