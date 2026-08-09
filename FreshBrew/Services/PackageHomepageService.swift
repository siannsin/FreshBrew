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
        packageName: String,
        kind: HomebrewPackageKind,
        homepageURL: URL?
    ) async throws -> Bool
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

    private func storedURLs() -> [String: String] {
        defaults.object(forKey: Self.key) as? [String: String] ?? [:]
    }

    private static func validatedURL(from value: String?) -> URL? {
        guard let value,
              let components = URLComponents(string: value),
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
        packageName: String,
        kind: HomebrewPackageKind,
        homepageURL: URL? = nil
    ) async throws -> Bool {
        let packageID = "\(kind.rawValue):\(packageName)"
        if let homepageURL {
            store.save([packageID: homepageURL])
            return await openURL(homepageURL)
        }
        if let cachedURL = store.url(for: packageID) {
            return await openURL(cachedURL)
        }

        let resolvedURL = try await homepageResolver.packageHomepageURL(
            packageName: packageName,
            kind: kind
        )
        store.save([packageID: resolvedURL])
        return await openURL(resolvedURL)
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
