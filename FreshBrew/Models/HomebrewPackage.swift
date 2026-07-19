import Foundation

enum HomebrewPackageKind: String, Codable, CaseIterable, Sendable {
    case formula
    case cask
}

struct HomebrewPackage: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let installedVersion: String
    let availableVersion: String
    let kind: HomebrewPackageKind

    var id: String {
        "\(kind.rawValue):\(name)"
    }
}

struct UpdatedPackage: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let previousVersion: String
    let installedVersion: String
    let kind: HomebrewPackageKind

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
