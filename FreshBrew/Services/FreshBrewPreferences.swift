import Foundation

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

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
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

    private func read<T>(_ operation: (UserDefaults) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation(defaults)
    }

    private func write(_ operation: (UserDefaults) -> Void) {
        lock.lock()
        operation(defaults)
        lock.unlock()
    }
}
