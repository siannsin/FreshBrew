import Foundation

enum HomebrewPackageKind: String, Codable, CaseIterable, Sendable {
    case formula
    case cask
}

struct HomebrewPackage: Identifiable, Codable, Hashable, Sendable {
    static let freshBrewCaskID = "cask:freshbrew"

    let name: String
    let installedVersion: String
    let availableVersion: String
    let kind: HomebrewPackageKind
    let homepageURL: URL?

    init(
        name: String,
        installedVersion: String,
        availableVersion: String,
        kind: HomebrewPackageKind,
        homepageURL: URL? = nil
    ) {
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.kind = kind
        self.homepageURL = homepageURL
    }

    var id: String {
        "\(kind.rawValue):\(name)"
    }

    var isFreshBrewCask: Bool {
        id == Self.freshBrewCaskID
    }
}

struct UpdatedPackage: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let previousVersion: String
    let installedVersion: String
    let kind: HomebrewPackageKind
    let homepageURL: URL?

    init(
        name: String,
        previousVersion: String,
        installedVersion: String,
        kind: HomebrewPackageKind,
        homepageURL: URL? = nil
    ) {
        self.name = name
        self.previousVersion = previousVersion
        self.installedVersion = installedVersion
        self.kind = kind
        self.homepageURL = homepageURL
    }

    var id: String {
        "\(kind.rawValue):\(name)"
    }
}

enum HomebrewVersionDisplay {
    static func compact(_ version: String, kind: HomebrewPackageKind) -> String {
        guard kind == .cask,
              let commaIndex = version.firstIndex(of: ",") else {
            return version
        }

        let primaryVersion = version[..<commaIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return primaryVersion.isEmpty ? version : primaryVersion
    }

    static func compactTransition(for package: UpdatedPackage) -> String {
        "\(compact(package.previousVersion, kind: package.kind)) → "
            + "\(compact(package.installedVersion, kind: package.kind))"
    }

    static func compactTransition(for package: HomebrewPackage) -> String {
        let installedVersion = compact(package.installedVersion, kind: package.kind)
        let availableVersion = compact(package.availableVersion, kind: package.kind)
        return "\(installedVersion) → \(availableVersion)"
    }

    static func fullTransition(for package: UpdatedPackage) -> String {
        "\(package.previousVersion) → \(package.installedVersion)"
    }
}
