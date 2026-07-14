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
