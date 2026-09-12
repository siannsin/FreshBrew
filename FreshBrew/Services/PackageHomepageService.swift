import AppKit
import Foundation

protocol PackageHomepageResolving: Sendable {
    func packageHomepageURLs(
        for packages: [HomebrewPackage]
    ) async -> [String: URL]

    func packageHomepageURL(
        packageName: String,
        kind: HomebrewPackageKind
    ) async throws -> URL
}

protocol PackageHomepageOpening: Sendable {
    @discardableResult
    func openPage(
        packageID: String,
        packageName: String,
        kind: HomebrewPackageKind,
        homepageURL: URL?
    ) async throws -> Bool
}

enum PackageHomepageURLValidator {
    nonisolated static func validatedURL(from value: String) -> URL? {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalizedValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    nonisolated static func validate(_ url: URL) throws -> URL {
        guard let validatedURL = validatedURL(from: url.absoluteString) else {
            throw PackageHomepageError.invalidURL(url.absoluteString)
        }
        return validatedURL
    }
}

final class PackageHomepageStore: @unchecked Sendable {
    private static let key = "packageHomepageURLs"

    private let defaults: any PreferencesStoring
    private let lock = NSLock()

    init(defaults: any PreferencesStoring = UserDefaults.standard) {
        self.defaults = defaults
    }

    func url(for packageID: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return Self.validatedURL(from: storedURLs()[packageID])
    }

    func save(_ urls: [String: URL]) {
        guard !urls.isEmpty else { return }
        lock.lock()
        var stored = storedURLs()
        for (packageID, url) in urls {
            guard Self.validatedURL(from: url.absoluteString) != nil else { continue }
            stored[packageID] = url.absoluteString
        }
        defaults.set(stored, forKey: Self.key)
        lock.unlock()
    }

    func migrateURL(from legacyPackageID: String, to packageID: String) {
        guard legacyPackageID != packageID else { return }
        lock.lock()
        defer { lock.unlock() }
        var stored = storedURLs()
        guard let legacyURL = stored[legacyPackageID] else { return }
        if stored[packageID] == nil {
            stored[packageID] = legacyURL
        }
        stored.removeValue(forKey: legacyPackageID)
        defaults.set(stored, forKey: Self.key)
    }

    private func storedURLs() -> [String: String] {
        defaults.object(forKey: Self.key) as? [String: String] ?? [:]
    }

    private static func validatedURL(from value: String?) -> URL? {
        guard let value else { return nil }
        return PackageHomepageURLValidator.validatedURL(from: value)
    }
}

struct PackageHomepageService: PackageHomepageOpening, Sendable {
    private let homepageResolver: any PackageHomepageResolving
    private let store: PackageHomepageStore
    private let openURL: @MainActor @Sendable (URL) -> Bool

    init(
        homepageResolver: any PackageHomepageResolving = HomebrewService(),
        store: PackageHomepageStore = PackageHomepageStore(),
        openURL: @escaping @MainActor @Sendable (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) {
        self.homepageResolver = homepageResolver
        self.store = store
        self.openURL = openURL
    }

    @discardableResult
    func openPage(
        packageID: String,
        packageName: String,
        kind: HomebrewPackageKind,
        homepageURL: URL? = nil
    ) async throws -> Bool {
        if let homepageURL {
            return try await saveAndOpen(homepageURL, for: packageID)
        }
        if let cachedURL = store.url(for: packageID) {
            return try await openValidated(cachedURL)
        }

        let resolvedURL = try await homepageResolver.packageHomepageURL(
            packageName: packageName,
            kind: kind
        )
        return try await saveAndOpen(resolvedURL, for: packageID)
    }

    private func saveAndOpen(_ url: URL, for packageID: String) async throws -> Bool {
        let validatedURL = try PackageHomepageURLValidator.validate(url)
        store.save([packageID: validatedURL])
        return await openURL(validatedURL)
    }

    private func openValidated(_ url: URL) async throws -> Bool {
        let validatedURL = try PackageHomepageURLValidator.validate(url)
        return await openURL(validatedURL)
    }
}

enum PackageHomepageError: Error, Equatable, Sendable {
    case unavailable
    case invalidURL(String)
}

extension PackageHomepageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Homebrew did not provide a homepage for this package."
        case .invalidURL:
            return "Homebrew provided an invalid package homepage."
        }
    }
}

extension HomebrewService: PackageHomepageResolving {}
