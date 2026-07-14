import Foundation

enum AutomaticCheckMode: String, Codable, CaseIterable, Sendable {
    case afterUnlock
    case periodic
}
