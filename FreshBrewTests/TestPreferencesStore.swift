import Foundation
@testable import FreshBrew

final class InMemoryPreferencesStore: PreferencesStoring {
    private var values: [String: Any] = [:]
    private var registeredValues: [String: Any] = [:]

    func register(defaults registrationDictionary: [String: Any]) {
        registeredValues.merge(registrationDictionary) { _, newValue in newValue }
    }

    func object(forKey defaultName: String) -> Any? {
        values[defaultName] ?? registeredValues[defaultName]
    }

    func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    func bool(forKey defaultName: String) -> Bool {
        if let value = object(forKey: defaultName) as? Bool {
            return value
        }
        return (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    func double(forKey defaultName: String) -> Double {
        if let value = object(forKey: defaultName) as? Double {
            return value
        }
        return (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }
}
